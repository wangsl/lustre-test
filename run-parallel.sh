#!/bin/bash

# $Id$ 

working_dir=/scratch/wang/fs-test

parallel=/home/wang/FS-test/lustre-test/parallel.pl

fs_test=/home/wang/FS-test/lustre-test/fs-test.py

nodes=(
    compute-4-0
    compute-4-1
    compute-4-2
    compute-4-3
    compute-4-4
    compute-4-5
    compute-4-8
    compute-4-15
    compute-5-0
    compute-5-1
    compute-5-2
    compute-5-3
    compute-5-4
    compute-5-5
    compute-12-0
    compute-12-1
    compute-12-2
    compute-12-3
    compute-12-4
    compute-12-5
)

n_nodes=${#nodes[*]}

echo $n_nodes

grep_nodes=
parallel_nodes=
for((i=0; i<$n_nodes; i++)); do
    echo ${nodes[$i]}
    parallel_nodes="$parallel_nodes -S ${nodes[$i]}"
    grep_nodes="$grep_nodes|${nodes[$i]}-ib"
done

echo $grep_nodes | sed -e 's/^|//g'

cd $working_dir

echo 
echo "Job starts: $(date)"

{ 
    for((i=0; i<1200; i++)); do 
	echo "dir=$working_dir/\$(hostname -a)/\$\$; mkdir -p \$dir; cd \$dir; python -u $fs_test"
    done 
} | perl $parallel --no-notice -j12 $parallel_nodes

echo
echo "Job ends: $(date)"

exit

# { for c in compute-*; do echo rm -rf $c; done } | /home/wang/FS-test/lustre-test/parallel.pl -j20
 
# { for c in compute-*/*; do echo rm -rf  $c; done } | /home/wang/FS-test/lustre-test/parallel.pl --no-notice -j60 
