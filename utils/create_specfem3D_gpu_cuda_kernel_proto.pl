#!/usr/bin/perl
#
#
#  Script to extract the function declarations in cuda kernel files
#
#
# usage: ./create_specfem3D_gpu_cuda_kernel_proto.pl
# run in directory root SPECFEM3D/
#

$outfile = "src/gpu/kernels/kernel_proto.cu.h";


open(IOUT,"> _____temp_tutu_____");

$header = <<END;
/*
!=====================================================================
!
!               S p e c f e m 3 D  V e r s i o n  3 . 0
!               ---------------------------------------
!
!    Main historical authors: Dimitri Komatitsch and Jeroen Tromp
!                             CNRS, France
!                      and Princeton University, USA
!                (there are currently many more authors!)
!                          (c) October 2017
!
! This program is free software; you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation; either version 3 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License along
! with this program; if not, write to the Free Software Foundation, Inc.,
! 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
!
!=====================================================================
*/

// this file has been automatically generated by script utils/create_specfem3D_gpu_cuda_kernel_proto.pl

#ifndef KERNEL_PROTO_CUDA_H
#define KERNEL_PROTO_CUDA_H

// prototype definitions from cuda kernel files
END

$footer = <<END;
#endif  // KERNEL_PROTO_CUDA_H
END

print IOUT "$header\n";

$success = 0;

@objects = `ls src/gpu/kernels/*.cu`;

foreach $name (@objects) {
  chop $name;
  print "extracting word in file $name ...\n";

  print IOUT "\n//\n// $name\n//\n\n";

  # change tabs to white spaces
  system("expand -2 < $name > _____temp_tutu01_____");
  open(IIN,"<_____temp_tutu01_____");

  # open the source file
  $success = 1;
  $do_extract = 0;
  while($line = <IIN>) {
    chop $line;

    # suppress trailing white spaces and carriage return
    $line =~ s/\s*$//;

    if( $line =~ /^\// || $line =~ /^\#/){
      # skip line which starts with # (ifdef/endif) or // (comment)
      next;
    }

    if($line =~ /__global__/){
      # new function declaration starts
      #print "$line\n";
      if( $line =~ /template __global__/ ){
        # skip function definitions (from an explicit template instantiation)
        $do_extract = 0;
      }else{
        $do_extract = 1;
      }
    }

    # extract section
    if($do_extract == 1 ){
      # kernel_2 function declarations
      if( $line =~ /__launch_bounds__/ ){
        # skip line with launch_bounds definition
        next;
      }
      if( $line =~ /^\// || $line =~ /^\#/){
        # skip line which starts with # (ifdef/endif) or // (comment)
        next;
      }
      # function declaration
      if($line =~ /\)/){
        # function declaration ends
        # remove trailing {
        $line =~ s/{//;
        print IOUT "$line\;\n\n";
        $do_extract = 0;
      }else{
        # write line to the output file
        print IOUT "$line\n";
      }
      next;
    }
  }
  close(IIN);

  if( $success == 0 ){ exit; }
}

print IOUT "$footer\n";
close(IOUT);

system("rm -f _____temp_tutu01_____");

# creates new stubs file if successful
if( $success == 1 ){
  print "\n\nsuccessfully extracted declarations \n\n";
  system("cp -p $outfile $outfile.bak");
  system("cp -p _____temp_tutu_____ $outfile");
  print "created new: $outfile \n";
}
system("rm -f _____temp_tutu_____");


