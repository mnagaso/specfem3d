# Container files for easy configuration of SPECFEM3D environment
This directry includes the files for preparing a calculation environment using container tools.  
Docker and Singularity scripts are placed in  

```
specfem3d/container_files/docker_files      # docker files
specfem3d/container_files/singularity_files # singularity files
```

Guidance for installation follows below  


## Build SPECFEM3D in Docker container
At first, `docker` and `docker-compose` command need to be runnable.  
Installation guidance may be found [here for docker](https://docs.docker.com/install/) and [here for docker-compose](https://docs.docker.com/compose/install/).

Secondly, it is necessary to make a simlink of `docker-compose.yml` in the `specfem3d` directory.  

If you are in `specfem3d/container_files`, run below to create this link,  
```bash
ln -s docker_files/docker-compose.yml ../
```

then run the command below to build the docker container,  
```bash
docker-compose up -d
```  

To check the created container,  
```bash
docker-compose ps
```  

then this will show the message like below,  
```
           Name               Command    State    Ports
-------------------------------------------------------
specfem3d_spec_1   /bin/bash   Exit 0  
```

To enter into this container and run the test simulation,
```
docker attach specfem3d_spec_1
cd /specfem3d
./run_this_example.sh
```

The explanation of files in `docker_files` directory:  
```
Dockerfile          # terminal commands which will be run during the build.
docker-compose.yml  # build/run script for facilitating the build and attach.
```

The files modified and generated in the container will not be reflected in the local environment in this setup.  
In order to link the local and docker container's environment, `docker-compose.yml` need to be modified from  
```
version: '3'
services:
  spec:
    build:
      context: .
      dockerfile: ./container_files/docker_files/Dockerfile
      #volumes:
      #  - .:/specfem3d
    tty: true
    stdin_open: true
```
to  
```
version: '3'
services:
  spec:
    build:
      context: .
      dockerfile: ./container_files/docker_files/Dockerfile
      volumes:
        - .:/specfem3d
    tty: true
    stdin_open: true
```
This will bind the local specfem3d directory to the docker container.  
Re-configure and make will be necessary after `docker attach` with this binding.


---
## Build SPECFEM3D on Singularity

`singularity` command need to be available in the working environment.  
Installation guidance may be found [here](https://sylabs.io/guides/3.5/user-guide/quick_start.html#quick-installation-steps).  

`singularity_files` directory includes the two files below:
```
specfem_envphdf5gpu.def  # definition file for preparing parallel hdf5 and cuda 10.1 env
specfem_core_gpu.def     # definition file for compiling specfem3d on the env built by specfem_envphdf5gpu.def
test                     # test scripts to run_this_example.sh with gpu setup
```

The build command,  
```
sudo singularity build specfem_core_gpu.sif specfem_core_gpu.def
```
will create the `.sif` file then we can test this build with the script `test/run_this_example_on_singularity.sh`

Depending on the type of graphic cards in the local environment, `--with-cuda=cuda9` may be required to be modified before running this build command.  
`mpich` in local environment is also necessary for this setup.  

`specfem_core_gpu.def` will use the pre-build parallel hdf5 environment,  
while users may build by themselves  
```
sudo singularity build specfem_envphdf5gpu.sif specfem_envphdf5gpu.def
```
and modify the head of `specfem_core_gpu.def` from  
```
# using the pre-build image
Bootstrap: library
From: mnagaso/default/phdf5env:gpu_v1

# using local image
#Bootstrap: localimage
#From: ./specfem_envphdf5gpu.sif
```
to  
```
# using the pre-build image
#Bootstrap: library
#From: mnagaso/default/phdf5env:gpu_v1

# using local image
Bootstrap: localimage
From: ./specfem_envphdf5gpu.sif
```

Instead of running the commands on singularty environment from local, users may enter into the singularity image like `attach` command of docker,  
```
singularity shell specfem_core_gpu.sif
```

Running commands in singularity image from outside as `test/run_this_example_on_singularity.sh` will generate the output files directry in the local files, so the binding directory like docker container is not necessary.  
`sudo singularity build specfem_core_gpu.sif specfem_core_gpu.def` need to be done again after modifying any file in specfem3d directory, to reflect thosemodification into the singularity image.  