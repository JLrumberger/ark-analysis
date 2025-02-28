# Runs consensus clustering on the pixel data averaged across all channels

# Usage: Rscript {fovs} {markers} {maxK} {cap} {pixelMatDir} {clusterAvgPath} {clustToMetaPath} {seed}

# - fovs: list of fovs to cluster
# - markers: list of channel columns to use
# - maxK: number of consensus clusters
# - cap: max z-score cutoff
# - pixelMatDir: path to the pixel data with SOM clusters
# - clusterAvgPath: path to the averaged cluster data
# - clustToMetaPath: path to file where the SOM cluster to meta cluster mapping will be written
# - seed: random factor

suppressPackageStartupMessages({
    library(arrow)
    library(ConsensusClusterPlus)
    library(data.table)
    library(doParallel)
    library(foreach)
    library(parallel)
    library(stringi)
})

# get the number of cores
nCores <- parallel::detectCores() - 1

# get the command line arguments
args <- commandArgs(trailingOnly=TRUE)

# create the list of fovs
fovs <- unlist(strsplit(args[1], split=","))

# create the list of channels
markers <- unlist(strsplit(args[2], split=","))

# get number of consensus clusters
maxK <- strtoi(args[3])

# get z-score scaling factor
cap <- strtoi(args[4])

# get path to the pixel data
pixelMatDir <- args[5]

# get path to the averaged channel data
clusterAvgPath <- args[6]

# get the clust to meta write path
clustToMetaPath <- args[7]

# retrieve the batch size to determine number of threads to run in parallel
batchSize <- strtoi(args[8])

# set the random seed
seed <- strtoi(args[9])
set.seed(seed)

# read cluster averaged data
print("Reading cluster averaged data")
clusterAvgs <- as.data.frame(read.csv(clusterAvgPath, check.names=FALSE))

# z-score and cap the data accordingly
# NOTE: capping cluster avg data produces better clustering results
# NOTE: need to cap with sapply because pmin sets out-of-range values to NA on non-vectors
clusterAvgsScale <- clusterAvgs[,markers]
clusterAvgsScale <- scale(clusterAvgs[,markers])
clusterAvgsScale <- sapply(as.data.frame(clusterAvgsScale), pmin, cap)
clusterAvgsScale <- sapply(as.data.frame(clusterAvgsScale), pmax, -cap)

# run the consensus clustering
print("Running consensus clustering")
suppressMessages(consensusClusterResults <- ConsensusClusterPlus(t(clusterAvgsScale), maxK=maxK, seed=seed))
som_to_meta_map <- consensusClusterResults[[maxK]]$consensusClass
names(som_to_meta_map) <- clusterAvgs$pixel_som_cluster

# define variable to keep track of number of fovs processed
fovsProcessed <- 0

# append pixel_meta_cluster to each fov's data
print("Mapping pixel data to consensus cluster labels")
for (batchStart in seq(1, length(fovs), batchSize)) {
    # define the parallel cluster for this batch of fovs
    # NOTE: to prevent the occassional hanging first FOV issue, we need to log to an outfile
    # to "force" a return out of the foreach loop in this case
    parallelCluster <- parallel::makeCluster(nCores, type="FORK", outfile='log.txt')

    # register parallel cluster for dopar
    doParallel::registerDoParallel(cl=parallelCluster)

    # need to prevent overshooting end of fovs list when batching
    batchEnd <- min(batchStart + batchSize - 1, length(fovs))

    # run the multithreaded batch process for mapping to SOM labels and saving
    fovStatuses <- foreach(
        i=batchStart:batchEnd,
        .combine=rbind
    ) %dopar% {
        fileName <- paste0(fovs[i], '.feather')
        matPath <- file.path(pixelMatDir, fileName)

        status <- tryCatch(
            {
                fovPixelData <- arrow::read_feather(matPath)

                # assign hierarchical cluster labels
                fovPixelData$pixel_meta_cluster <- som_to_meta_map[as.character(fovPixelData$pixel_som_cluster)]

                # write data with consensus labels
                tempPath <- file.path(paste0(pixelMatDir, '_temp'), fileName)
                arrow::write_feather(as.data.table(fovPixelData), tempPath, compression='uncompressed')

                # this won't be displayed to the user but is used as a helper to break out
                # in the rare first FOV hang issue
                print(paste('Done writing fov', fovs[i]))
                0
            },
            error=function(cond) {
                # this won't be displayed to the user but is used as a helper to break out
                # in the rare first FOV hang issue
                print(paste('Error encountered for fov', fovs[i]))
                1
            }
        )

        data.frame(fov=fovs[i], status=status)
    }

    # report any erroneous feather files
    for (i in 1:nrow(fovStatuses)) {
        if (fovStatuses[i, 'status'] == 1) {
            print(paste("The data for FOV", fovStatuses[i, 'fov'], "has been corrupted, removing"))
            fovsProcessed <- fovsProcessed - 1
        }
    }

    # unregister the parallel cluster
    parallel::stopCluster(cl=parallelCluster)

    # update number of fovs processed
    fovsProcessed <- fovsProcessed + (batchEnd - batchStart + 1)

    # inform user that batchSize fovs have been processed
    print(paste("Processed", as.character(fovsProcessed), "fovs"))

    # remove log.txt
    unlink('log.txt')
}

# save the mapping from pixel_som_cluster to pixel_meta_cluster
print("Writing SOM to meta cluster mapping table")
som_to_meta_map_table <- as.data.table(som_to_meta_map)

# assign pixel_som_cluster column, then rename som_to_meta_map to pixel_meta_cluster
som_to_meta_map_table$pixel_som_cluster <- as.integer(rownames(som_to_meta_map_table))
som_to_meta_map_table <- setnames(som_to_meta_map_table, "som_to_meta_map", "pixel_meta_cluster")
arrow::write_feather(som_to_meta_map_table, clustToMetaPath, compression='uncompressed')
