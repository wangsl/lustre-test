#!/bin/bash

# $Id$ 

#PBS -V
#PBS -N FStest
#PBS -l nodes=40:ppn=12,mem=400GB,walltime=12:00:00

working_dir=/scratch/wang/fs-test-2

cd $working_dir

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

{
    
    if [ "$PBS_NODEFILE" != "" ]; then
	nodes=($(cat $PBS_NODEFILE | sort -u | sed -e 's/.local$//'))
    fi
    
    n_nodes=${#nodes[*]}
    
    echo $n_nodes
    
    grep_nodes=
    parallel_nodes=
    for((i=0; i<$n_nodes; i++)); do
	echo ${nodes[$i]}
	parallel_nodes="$parallel_nodes -S ${nodes[$i]}"
	grep_nodes="$grep_nodes|${nodes[$i]}-ib"
    done
    
    echo
    echo $grep_nodes | sed -e 's/^|//g'
    
    echo 
    echo "Job starts: $(date)"
    
    { 
	for((i=0; i<1440; i++)); do 
	    echo "dir=$working_dir/\$(hostname -a)/\$\$; mkdir -p \$dir; cd \$dir; python -u $fs_test"
	done 
    } | perl $parallel --no-notice -j12 $parallel_nodes
    
    echo
    echo "Job ends: $(date)"
} 2>&1 | tee output.log
    
exit

# { for c in compute-*; do echo rm -rf $c; done } | /home/wang/FS-test/lustre-test/parallel.pl -j20
 
# { for c in compute-*/*; do echo rm -rf  $c; done } | /home/wang/FS-test/lustre-test/parallel.pl --no-notice -j60 
