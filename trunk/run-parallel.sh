#!/bin/bash

# $Id$ 

working_dir=/scratch/wang/fs-test

parallel=/home/wang/FS-test/lustre-test/parallel.pl

fs_test=/home/wang/FS-test/lustre-test/fs-test.py

nodes=(
    compute-4-0.local
    compute-4-1.local
    compute-4-2.local
    compute-4-3.local
    compute-4-4.local
    compute-4-5.local
    compute-4-8.local
    compute-4-15.local
    compute-5-0.local
    compute-5-1.local
    compute-5-2.local
    compute-5-3.local
    compute-5-4.local
    compute-5-5.local
    compute-12-0
    compute-12-1
    compute-12-2
    compute-12-3
    compute-12-4
    compute-12-5
)

echo ${#nodes[*]}

parallel_nodes=
for((i=0; i<20; i++)); do
    echo ${nodes[$i]}
    parallel_nodes="$parallel_nodes -S ${nodes[$i]}"
done

cd $working_dir

{ 
    for((i=0; i<1008; i++)); do 
	echo "dir=$working_dir/\$(hostname -a)/\$\$; mkdir -p \$dir; cd \$dir; python -u $fs_test"
    done 
} | perl $parallel --no-notice -j12 $parallel_nodes

exit

# { for c in compute-*; do echo rm -rf $c; done } | /home/wang/FS-test/lustre-test/parallel.pl -j20
 
# { for c in compute-*/*; do echo rm -rf  $c; done } | /home/wang/FS-test/lustre-test/parallel.pl --no-notice -j60 
