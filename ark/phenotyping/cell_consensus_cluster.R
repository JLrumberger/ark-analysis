# Runs consensus clustering on the averaged cell data table (created by compute_cell_cluster_avg) 
# defined as the mean counts of each SOM pixel/meta cluster across all cell SOM clusters in each fov
# (m x n table, where m is the number of cell SOM/meta clusters and n is the number of pixel SOM/meta clusters).

# Usage: Rscript {pixelClusterCol} {maxK} {cap} {cellMatPath} {clusterAvgPath} {clustToMeta} {seed}

# - pixelClusterCol: the prefix of the columns defining pixel SOM/meta cluster counts per cell
# - maxK: number of consensus clusters
# - cap: maximum z-score cutoff
# - cellMatPath: path to the cell-level data containing the counts of each SOM pixel/meta clusters per cell, labeled with cell SOM clusters
# - clusterAvgPath: path to the averaged cell data table (as defined above)
# - clustToMeta: path to file where the SOM cluster to meta cluster mapping will be written
# - seed: random factor

suppressPackageStartupMessages({
    library(arrow)
    library(data.table)
    library(ConsensusClusterPlus)
})

# get the command line arguments
args <- commandArgs(trailingOnly=TRUE)

# get the cluster cols to subset over
pixelClusterCol <- args[1]

# get number of consensus clusters
maxK <- strtoi(args[2])

# get z-score scaling factor
cap <- strtoi(args[3])

# get the path to the cell data (with SOM labels)
cellMatPath <- args[4]

# get path to the averaged cluster data
clusterAvgPath <- args[5]

# get the clust to meta write path
clustToMeta <- args[6]

# set the random seed
seed <- strtoi(args[7])
set.seed(seed)

print("Reading cluster averaged data")
clusterAvgs <- as.data.frame(read.csv(clusterAvgPath, check.names=FALSE))

# z-score and cap the data respectively
# NOTE: capping cluster avg data produces better clustering results
# NOTE: need to cap with sapply because pmin sets out-of-range values to NA on non-vectors
print("Scaling data")
clusterCols <- colnames(clusterAvgs)[grepl(pattern=sprintf('%s_', pixelClusterCol),
                                     colnames(clusterAvgs))]
clusterAvgsScale <- scale(clusterAvgs[,clusterCols])
clusterAvgsScale <- sapply(as.data.frame(clusterAvgsScale), pmin, cap)
clusterAvgsScale <- sapply(as.data.frame(clusterAvgsScale), pmax, -cap)

# run the consensus clustering
print("Running consensus clustering")
suppressMessages(consensusClusterResults <- ConsensusClusterPlus(t(clusterAvgsScale), maxK=maxK, seed=seed))
som_to_meta_map <- consensusClusterResults[[maxK]]$consensusClass
names(som_to_meta_map) <- clusterAvgs$cell_som_cluster

# append cell_meta_cluster to data
print("Writing consensus clustering")
cellClusterData <- arrow::read_feather(cellMatPath)
cellClusterData$cell_meta_cluster <- som_to_meta_map[as.character(cellClusterData$cell_som_cluster)]
arrow::write_feather(as.data.table(cellClusterData), cellMatPath, compression='uncompressed')

# save the mapping from cell_som_cluster to cell_meta_cluster
print("Writing SOM to meta cluster mapping table")
som_to_meta_map <- as.data.table(som_to_meta_map)

# assign cell_som_cluster column, then rename som_to_meta_map to cell_meta_cluster
som_to_meta_map$cell_som_cluster <- as.integer(rownames(som_to_meta_map))
som_to_meta_map <- setnames(som_to_meta_map, "som_to_meta_map", "cell_meta_cluster")
arrow::write_feather(som_to_meta_map, clustToMeta, compression='uncompressed')
