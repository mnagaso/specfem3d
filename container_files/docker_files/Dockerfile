FROM nvidia/cuda:10.1-cudnn7-devel-ubuntu18.04

LABEL maintainer="Masaru Nagaso <mnsaru22@gmail.com>"


# Update the apt-get and installs necessary libraries
RUN apt-get update \
  && apt-get install -y \
    wget \
    build-essential \
    git \
    gfortran \
    zlib1g-dev

# build parallel hdf5

## Specify install paths for HDF5 and dependencies
ENV LIBPATH /Libraries 
ENV MPIv=3.3
ENV ZLIBv=1.2.11
ENV HDF5v=1.10.5
ENV MPICH=$LIBPATH/mpich-${MPIv} \
    ZLIB=$LIBPATH/zlib-${ZLIBv} \
    HDF5=$LIBPATH/hdf5-${HDF5v} 

## download source codes
ENV LD_LIBRARY_PATH=${MPICH}/lib:${HDF5}/lib PATH=${MPICH}/bin:${HDF5}/bin:${PATH}
WORKDIR ${LIBPATH}_SRC
RUN wget http://www.mpich.org/static/downloads/$MPIv/mpich-${MPIv}.tar.gz \
      http://zlib.net/zlib-${ZLIBv}.tar.gz \
      https://support.hdfgroup.org/ftp/HDF5/releases/hdf5-${HDF5v%.*}/hdf5-${HDF5v}/src/hdf5-${HDF5v}.tar.bz2 && \
      tar xzf mpich-${MPIv}.tar.gz && tar xzf zlib-${ZLIBv}.tar.gz && tar xjf hdf5-${HDF5v}.tar.bz2

## compile libraries
### ==== mpich ====
WORKDIR mpich-${MPIv}
RUN ./configure --prefix=${MPICH} --disable-cxx && \
    make && make install

### ==== zlib ====
WORKDIR ../zlib-${ZLIBv}
RUN ./configure && \
    make install prefix=$ZLIB

### ==== hdf5 ====
WORKDIR ../hdf5-${HDF5v}
RUN ./configure --prefix=$HDF5 --disable-static --enable-shared --enable-fortran --enable-parallel --with-zlib=$ZLIB/include,$ZLIB/lib && \
    make && make install 

WORKDIR ../..
RUN rm -rf ${LIBPATH}_SRC

# make specfem3d
## using local source
COPY . /specfem3d
## or git clone
#git clone --recursive --branch devel https://github.com/geodynamics/specfem3d.git

WORKDIR /specfem3d
RUN ./configure CC=gcc FC=gfortran MPIFC=mpif90 --with-mpi MPI_INC=$MPICH/include --with-cuda=cuda9 CUDA_LIB=/usr/local/cuda/lib64 && \
    make clean && make
