library(MASS)
library(earth)
library(skmeans)
library(ggplot2)
library(ModelMetrics)
library(caret)
library(compiler)
library(ROCR)
library(impute)

args <- commandArgs(trailingOnly = TRUE)
rdata.file <- args[1]

#### Functions: Run this code block first ####

# Unit normalization
make.unit <- function(x, center = T, rank = T) {
  if (rank) {
    return(make.unit(rank(x, ties.method = 'random'), center = center, rank = F))
  }
  
  if (center) {
    return(make.unit(x - mean(x), center = F, rank = F))
  }
  
  x.normed <- x/sqrt(sum(x^2))
  return(x.normed)
}

# Sample k features from each feature cluster that is at least min.size
sample.clusters <- function(clust.vec, k = 2, min.cluster.size = 20, use.names = T) {
  # sample k elements from each cluster at random
  clust.counts <- table(clust.vec)
  
  # Only keep feature clusters with at least min.size features
  good.clust <- as.numeric(sort(names(clust.counts)[clust.counts >= min.cluster.size]))
  
  # Sample k features from each "good cluster"
  clust.idx.list <- lapply(good.clust, function(clust) {
    sample(which(as.numeric(clust.vec) == clust), k)
  })
  clust.idx <- do.call(c, clust.idx.list)
  
  if ( use.names ) {
    return(names(clust.vec)[clust.idx]) # return feature names
  } else {
    return(clust.idx) # return feature indexes only
  }
}


# Input: MHL matrix (rows: MHBs, columns: samples)
# Output; dataframe with the GSI information for each MHB (row)
gsi <- function(mhl.matrix, min.frac = 0.6) {
  mhl.matrix <- as.matrix(mhl.matrix)
  
  groups <- names(table(colnames(mhl.matrix))) # unique sample groups (i.e. brain, liver, etc.)
  index <- colnames(mhl.matrix)
  
  n.rows <- nrow(mhl.matrix)
  gsi.results <- data.frame(region = rownames(mhl.matrix), group = character(n.rows), GSI = numeric(n.rows), 
                            refMax = numeric(n.rows), stringsAsFactors = F)
  
  for (i in 1:nrow(mhl.matrix)) {
    group.means <- tapply(as.numeric(mhl.matrix[i, ]), index, function(x) mean(x, na.rm = T))
    group.max <- group.means[which.max(group.means)]
    group.assign <- names(group.max)
    
    groups.use <- groups[groups != group.assign]
    mhb.gsi <- vapply(groups.use, function(g) {
      g.mean <- mean(mhl.matrix[i, which(index == g)], na.rm = T)
      g.mhb <- 1 - (10^g.mean)/(10^group.max)
      g.mhb
    }, 1.0)
    mhb.sum <- sum(mhb.gsi, na.rm = T)/(length(groups) - 1)
    
    # Allow each MHB to be assigned to multiple tissues
    group.mean.fracs <- group.means/group.max
    if(sum(group.mean.fracs > min.frac, na.rm = T) > 1){
      group.assign <- paste(names(group.mean.fracs[group.mean.fracs > min.frac]), collapse = ",")
    }
    
    gsi.results[i, "group"] <- group.assign
    gsi.results[i, "GSI"] <- mhb.sum
    gsi.results[i, "refMax"] <- group.max
  }
  
  return(gsi.results)
}

gsi <- cmpfun(gsi) # Compile gsi function for faster runtime


# Compute ROC for a binary classifier
pROC <- function(pred, fpr.stop) {
  perf <- performance(pred, 'tpr', 'fpr')
  for (iperf in seq_along(perf@x.values)){
    ind = which(perf@x.values[[iperf]] <= fpr.stop)
    perf@y.values[[iperf]] = perf@y.values[[iperf]][ind]
    perf@x.values[[iperf]] = perf@x.values[[iperf]][ind]
  }
  return(perf)
}


# Plot ROC curve
plot.roc <- function(scores, hits, title, max.fdr = 1.0) {
  is.hit <- factor(names(scores) %in% hits)
  
  pred <- prediction(scores, is.hit)
  perf <- pROC(pred, fpr.stop = max.fdr)
  auc.perf <- performance(pred, measure = "auc", fpr.stop = max.fdr)
  auc <- round(auc.perf@y.values[[1]]/max.fdr,3)
  
  # plotting the ROC curve
  perf@x.name <- ''
  perf@y.name <- ''
  plot(perf, col="red", lwd = 2, xlab = NULL, ylab = NULL, main = paste(title, '(AUC:', auc, ')'), ylim = c(0,1))
  abline(a = 0, b = 1, lty = 2, lwd = 1)
  
  return(perf)
}


# function for getting features
get.features <- function(earth.model) {
  feature.idx <- which(sapply(earth.model$namesx.org, function(r) any(grepl(r, rownames(earth.model$coefficients)))))
  earth.model$namesx.org[feature.idx]
}



#### Load matrices and metadata ####

# Load processed and imputed data using an RData file
load(rdata.file)

# # Uncomment below to redo pre-processing and imputation on raw matrices
# source("preprocess_data.R")
# orig.data <- gen.data(rrbs.meta.file = 'RRBS.getHaplo.sampleInfo.txt',
#                       wgbs.meta.file = 'WGBS.getHaplo.sampleInfo.txt',
#                       rrbs.file = 'RRBS_170609.gethaplo.mhl.mhbs1.0.useSampleID.txt',
#                       wgbs.file = 'WGBS.getHaplo.mhl.mhbs1.0.rmdup_consistent.useSampleID.txt')


seed <- 348742 # Set random seed for reproducibility

# keep WGBS samples in the following tissue classes
keep.tissues <- c('colon', 'lung', 'neural', "heart", "liver", "lung", "pancreas", "stomach")
wgbs.meta <- orig.data$wgbs.meta[(orig.data$wgbs.meta$Tissue.Type %in% keep.tissues) & (orig.data$wgbs.meta$Type == "normal"),]
#tumor.meta <- orig.data$wgbs.meta[ orig.data$wgbs.meta$Type == "cancer" ,]
#wgbs.dat <- orig.data$wgbs.dat[, c(wgbs.meta$Sample.ID, tumor.meta$Sample.ID)]
#colnames(wgbs.dat) <- c(wgbs.meta$Tissue.Type, rep("tumor", nrow(tumor.meta)))

wgbs.dat <- orig.data$wgbs.dat[, c(wgbs.meta$Sample.ID)]
colnames(wgbs.dat) <- c(wgbs.meta$Tissue.Type)

# Select the tissue specific features from the WGBS tissue data, ranked by the group specific index (GSI)
feature.gsi <- gsi(wgbs.dat, min.frac = 0.8) # Calculate GSI for each feature
feature.gsi <- feature.gsi[order(feature.gsi$GSI, decreasing = T),]
tissue.specific.features <- feature.gsi[1:15000, "region"]

# Prep RRBS dataset
rrbs.dat <- t(orig.data$rrbs.dat[, orig.data$rrbs.meta$Type == 'Plasma'])
rrbs.dat <- rrbs.dat[,tissue.specific.features]
rrbs.tissue.labels <- orig.data$rrbs.meta[orig.data$rrbs.meta$Type == 'Plasma', "Tissue"]

#### Train test split
ncp.idx <- which(rrbs.tissue.labels == 'Normal')
ccp.idx <- which(rrbs.tissue.labels == 'Colon')
lcp.idx <- which(rrbs.tissue.labels == 'Lung')

set.seed(seed)
ncp.train <- sample(ncp.idx, 30)
ccp.train <- sample(ccp.idx, 20)
lcp.train <- sample(lcp.idx, 20)

ncp.test <- ncp.idx[!ncp.idx %in% ncp.train]
ccp.test <- ccp.idx[!ccp.idx %in% ccp.train]
lcp.test <- lcp.idx[!lcp.idx %in% lcp.train]

rrbs.train.dat <- rrbs.dat[c(ncp.train, ccp.train, lcp.train),]
rrbs.test.dat <- rrbs.dat[c(ncp.test, ccp.test, lcp.test),]

rrbs.train.labels <- factor(rrbs.tissue.labels[c(ncp.train, ccp.train, lcp.train)])
rrbs.test.labels<- factor(rrbs.tissue.labels[c(ncp.test, ccp.test, lcp.test)])


############## Binary classification ###################
########################################################

#### Ensemble model ####

# Parameters
ensemble.model.features <- 3 # Number of features to include in each model
N.MODELS <- 100 # Number of MARS models to include in the ensemble
n.cluster.features <- 3 # Numbe of feature to sample from each cluster
n.clusters <- 50 # Number of clusters to segment the features into

# Prep datasets
rrbs.dat <- as.data.frame(rrbs.dat)
rrbs.dat$tissue <- factor(rrbs.tissue.labels)

rrbs.train.dat <- as.data.frame(rrbs.train.dat)
rrbs.train.dat$tissue <- rrbs.train.labels

rrbs.test.dat <- as.data.frame(rrbs.test.dat)


# Segment the feature space into "n.clusters" clusters; 
# each model will see "n.cluster.features features from each cluster to reduce redundancy in the ensemble
intersect.markers <- intersect(rownames(orig.data$wgbs.dat), colnames(rrbs.dat))
wgbs.unit <- wgbs.dat[intersect.markers,]
for ( i in 1:nrow(wgbs.unit) ) {
  wgbs.unit[i,] <- make.unit(wgbs.unit[i,])
}

# cluster features with skmeans
set.seed(seed)
skm.res <- skmeans(wgbs.unit, n.clusters, method = 'pclust') 


# Create a list of features that each ensemble model will be able to use
set.seed(seed)
marker.index <- lapply(1:N.MODELS, function(i) {
  idx <- sample.clusters(skm.res$cluster, k = n.cluster.features, min.cluster.size = 20)
  idx <- idx[idx %in% colnames(rrbs.train.dat)]
  idx
})


# Train ensemble model on all training data
rrbs.ensemble.model <- lapply(marker.index, function(idx) {
  mdl <- earth(tissue ~ . -tissue, data = rrbs.train.dat[,c(idx, "tissue")], degree = 3, thresh = 0.0001, pmethod = 'backward', trace = 0, 
               nprune = ensemble.model.features, glm = list(family=binomial), linpreds = F)
  mdl
})


binary.marker.list <- sort(table(do.call(c, lapply(rrbs.ensemble.model, get.features))))
write.table(binary.marker.list, file="binary.marker.list.txt", sep="\t", quote=F)
save(rrbs.ensemble.model, file="binary.ensemble.model.Rdata")

# Test ensemble model on held out test data
# Creates a list of matrices (samples x tissues) of log-odds for each tissue class
rrbs.test.res <- lapply(1:N.MODELS, function(i) {
  idx <- marker.index[[i]]
  # For each sample, calculate the log-odds of the sample belonging to each tissue type (lung, normal, cancer)
  test.scores <- predict(rrbs.ensemble.model[[i]], rrbs.test.dat[,idx])
  rownames(test.scores) <- rownames(rrbs.test.dat)
  test.scores
})

true.labels <- rrbs.test.labels
combined.test.scores <- Reduce("+", rrbs.test.res)/N.MODELS # Simply sum the log-odds across the ensemble

# Calculate binary classifier AUC on held out test data and print results
rrbs.ensemble.auc <- mauc(true.labels, combined.test.scores)
names(rrbs.ensemble.auc$auc) <- colnames(combined.test.scores)
print(rrbs.ensemble.auc)

# Plot ROC curves for binary classifiers
tissue.perf <- lapply(colnames(combined.test.scores), function(ts) {
  roc.plot.title <- paste(ts, "vs", "other")
  x <- as.numeric(combined.test.scores[,ts])
  names(x) <- rownames(combined.test.scores)
  perf <- plot.roc(x, rownames(rrbs.test.dat[true.labels == ts,]), title = roc.plot.title)
  perf
})
names(tissue.perf) <- colnames(combined.test.scores)


############### Colon versus Lung Only ###############
######################################################

tissue.specific.features <- feature.gsi[ grep('colon|lung', feature.gsi$group)[1:15000], 'region']

# Prep RRBS dataset
rrbs.dat <- t(orig.data$rrbs.dat[, orig.data$rrbs.meta$Type == 'Plasma'])
rrbs.dat <- rrbs.dat[,tissue.specific.features]

rrbs.test.dat <- rrbs.dat[c(ccp.test, lcp.test),]

rrbs.train.dat <- rrbs.dat[c(ccp.train, lcp.train),]
rrbs.train.labels <- factor(rrbs.tissue.labels[c(ccp.train, lcp.train)])

rrbs.train.dat <- as.data.frame(rrbs.train.dat)
rrbs.train.dat$tissue <- rrbs.train.labels

#### Ensemble model ####

# Parameters
ensemble.model.features <- 2 # Number of features to include in each model
N.MODELS <- 500 # Number of MARS models to include in the ensemble
n.cluster.features <- 3 # Numbe of feature to sample from each cluster
n.clusters <- 50 # Number of clusters to segment the features into

# Create a list of features that each ensemble model will be able to use
set.seed(seed)
marker.index <- lapply(1:N.MODELS, function(i) {
  idx <- sample.clusters(skm.res$cluster, k = n.cluster.features, min.cluster.size = 20)
  idx <- idx[idx %in% colnames(rrbs.train.dat)]
  idx
})


# Train ensemble model on all training data
rrbs.ensemble.model <- lapply(marker.index, function(idx) {
  mdl <- earth(tissue ~ . -tissue, data = rrbs.train.dat[,c(idx, "tissue")], degree = 2, thresh = 0.0001, pmethod = 'backward', trace = 0, 
               nprune = ensemble.model.features, glm = list(family=binomial), linpreds = F)
  mdl
})

final.marker.list <- sort(table(do.call(c, lapply(rrbs.ensemble.model, get.features))))
fit <- plsda(rrbs.train.dat[, names(final.marker.list)], rrbs.train.labels, probMethod="soft", ncomp=3)


write.table(final.marker.list, file="tissue.marker.list.txt", sep="\t", quote=F)
save(fit, file="tissue_origin.model.Rdata")

# Prep test datasets

dat <- read.table(gzfile('ng.3805/RRBS_170609.gethaplo.mhl.mhbs1.0.useSampleID.txt.gz'),header=T,row=1)
rrbs.test.raw <- t(dat[names(final.marker.list), rownames(rrbs.test.dat)])
rrbs.test.imp <- impute.knn(rrbs.test.raw, k=10, rowmax=0.8)$data

rrbs.test.labels<- factor(rrbs.tissue.labels[c(ccp.test, lcp.test)])

# Create confusion matrix for multiclass prediction

table(rrbs.test.labels, predict(fit, rrbs.test.imp[ , names(final.marker.list)]))

