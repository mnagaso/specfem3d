#!/bin/bash

sif=../specfem_core_gpu.sif

echo "running example: `date`"
currentdir=`pwd`

# modify the Parfile parameter for not using hdf5 option
sed -i 's|GPU_MODE                        = .false.|GPU_MODE                        = .true.|g' ./DATA/Par_file

# sets up directory structure in current example directory
echo
echo "   setting up example..."
echo

rm -f -r OUTPUT_FILES

mkdir -p OUTPUT_FILES
mkdir -p OUTPUT_FILES/DATABASES_MPI

# stores setup
cp DATA/Par_file OUTPUT_FILES/
cp DATA/CMTSOLUTION OUTPUT_FILES/
cp DATA/STATIONS OUTPUT_FILES/

# get the number of processors, ignoring comments in the Par_file
NPROC=`grep ^NPROC DATA/Par_file | grep -v -E '^[[:space:]]*#' | cut -d = -f 2 | cut -d \# -f 1`
echo "The simulation will run on NPROC = " $NPROC " MPI tasks"

# decomposes mesh using the pre-saved mesh files in MESH-default
echo
echo "  decomposing mesh..."
echo
singularity exec $sif xdecompose_mesh $NPROC ./MESH-default ./OUTPUT_FILES/DATABASES_MPI/

# runs database generation
echo
echo "  running database generation on $NPROC processors..."
echo
mpirun.mpich -n $NPROC singularity exec $sif xgenerate_databases

# runs simulation
echo
echo "  running solver on $NPROC processors..."
echo
mpirun.mpich -n $NPROC singularity exec --nv $sif xspecfem3D

echo
echo "see results in directory: OUTPUT_FILES/"
echo
echo "done"
echo `date`


