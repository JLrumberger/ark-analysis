import os
import subprocess
import tempfile
from tempfile import TemporaryDirectory as tdir

import pytest
from testbook import testbook

from ark.utils import notebooks_test_utils

parametrize = pytest.mark.parametrize


SEGMENT_IMAGE_DATA_PATH = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                                       '..', '..', 'templates_ark', '1_Segment_Image_Data.ipynb')
PIXEL_CLUSTER_PATH = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                                  '..', '..', 'templates_ark', '2_Cluster_Pixels.ipynb')
CELL_CLUSTER_PATH = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                                 '..', '..', 'templates_ark', '3_Cluster_Cells.ipynb')


def _exec_notebook(nb_filename, base_folder):
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                        '..', '..', base_folder, nb_filename)
    with tempfile.NamedTemporaryFile(suffix=".ipynb") as fout:
        args = ["jupyter", "nbconvert", "--to", "notebook", "--execute",
                "--ExecutePreprocessor.timeout=1000",
                "--output", fout.name, path]
        subprocess.check_call(args)


# test runs with default inputs
def test_segment_image_data():
    _exec_notebook('1_Segment_Image_Data.ipynb', 'templates_ark')


def test_example_pairwise_spatial_enrichment():
    _exec_notebook('example_pairwise_spatial_enrichment.ipynb', 'templates_ark')


def test_example_neighborhood_analysis():
    _exec_notebook('example_neighborhood_analysis_script.ipynb', 'templates_ark')


# test folder inputs for image segmentation
@testbook(SEGMENT_IMAGE_DATA_PATH, timeout=6000)
def test_segment_image_data_folder(tb):
    with tdir() as tiff_dir, tdir() as input_dir, tdir() as output_dir, \
            tdir() as single_cell_dir, tdir() as viz_dir:
        # create input files
        notebooks_test_utils.segment_notebook_setup(tb,
                                                    deepcell_tiff_dir=tiff_dir,
                                                    deepcell_input_dir=input_dir,
                                                    deepcell_output_dir=output_dir,
                                                    single_cell_dir=single_cell_dir,
                                                    viz_dir=viz_dir)

        # hard coded fov setting
        notebooks_test_utils.fov_channel_input_set(
            tb,
            fovs=['fov0', 'fov1'],
            nucs_list=['chan0'],
            mems_list=['chan1', 'chan2']
        )

        # generate _feature_0 and _feature_1 tif files normally handled by create_deepcell_output
        notebooks_test_utils.generate_sample_feature_tifs(
            fovs=['fov0', 'fov1'],
            deepcell_output_dir=output_dir
        )

        # saves the segmentation mask overlay without channels
        notebooks_test_utils.overlay_mask(tb)

        # saves the segmentation mask overlay with channels
        notebooks_test_utils.overlay_mask(tb, channels=['nuclear_channel', 'membrane_channel'])

        # create the expression matrix
        notebooks_test_utils.create_exp_mat(tb)

        # create the expression matrix with nuclear counts
        notebooks_test_utils.create_exp_mat(tb, nuclear_counts=True)


# TODO: if needed, add MIBItiff tests
@testbook(PIXEL_CLUSTER_PATH, timeout=6000)
def test_pixel_clustering_folder(tb):
    with tdir() as base_dir:
        # setup the clustering process (also runs preprocessing)
        fovs, chans = notebooks_test_utils.flowsom_pixel_setup(
            tb, base_dir, create_seg_dir=True
        )

        # mock the clustering process
        notebooks_test_utils.flowsom_pixel_cluster(
            tb, base_dir, fovs, chans, create_seg_dir=True
        )

        notebooks_test_utils.flowsom_pixel_visualize(
            tb, base_dir, fovs
        )


@testbook(CELL_CLUSTER_PATH, timeout=6000)
@parametrize('pixel_cluster_col', ['pixel_meta_cluster_rename', 'pixel_som_cluster'])
def test_cell_clustering(tb, pixel_cluster_col):
    with tdir() as base_dir:
        # setup the clustering process
        fovs, chans = notebooks_test_utils.flowsom_cell_setup(
            tb, base_dir, 'sample_pixel_dir', pixel_cluster_col=pixel_cluster_col
        )

        # mock the clustering process
        notebooks_test_utils.flowsom_cell_cluster(
            tb, base_dir, fovs, chans, pixel_cluster_col=pixel_cluster_col
        )

        # run the visualization and remapping process
        notebooks_test_utils.flowsom_cell_visualize(
            tb, base_dir, fovs, pixel_cluster_col=pixel_cluster_col
        )
