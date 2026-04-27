#!/bin/bash

for in in tgbldq4oq22unr3fgm6nmauqdi446zol
do
    echo "Starting rollback for $in"
    ./01_scale_down.sh $in
    ./02_rollback.sh $in reset
#    ./02_rollback.sh $in restore
    ./03_verify_db.sh   $in

done 

