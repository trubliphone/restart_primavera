#!/bin/sh

#########################################
# restarts coupled model after failures #
# for HRCM on NEXCS or ARCHER           #
#########################################

###############
# global vars #
###############

declare -a MACHINES=("ARCHER" "NEXCS")

MACHINE="";
USER=$USER;
SUITE="";
CYCLE="";
SUITE_DIR="";
TEST=false;
VERBOSE=false;

#########
# usage #
#########

USAGE="Usage: `basename $0` -m <host machine: [`echo ${MACHINES[@]} | sed 's/ /|/g'`]> -s <suite-id> [-u <host user> (defaults to current user)] [-c <cycle-point> (defaults to last cycle)] [-d <suite directory on host machine> (useful if user is not the suite owner)] [-t (test mode)] [-v (verbose)]"

#############################
# get (and check) arguments #
#############################

while getopts m:u:s:c:d:tv OPT
do
  case $OPT in
    m) MACHINE="$OPTARG";;
    u) USER="$OPTARG";;
    s) SUITE="$OPTARG";;
    c) CYCLE="$OPTARG";;
    d) REMOTE_DIR="$OPTARG";;
    t) TEST=true;;
    v) VERBOSE=true;;
    *) echo $USAGE>&2;
       exit;;
  esac
done

# check all required arguments were provided...
if [ -z $MACHINE ] || [ -z $SUITE ]; then
  echo $USAGE>&2 && exit;
fi

# check valid suite was specified...
if [[ ! $SUITE =~ ^u-[a-z0-9]{5}$ ]]; then
  echo "ERROR: $SUITE is an invalid suite-id" >&2 && exit;
fi
SUITE_BASE=`echo $SUITE | cut -d'-' -f2`

# check valid machine was specified...
# and set machine-specific variables
if [ $MACHINE == "ARCHER" ]; then
    SSH_CMD="ssh -T -q -l $USER login.archer.ac.uk"
elif [ $MACHINE == "NEXCS" ]; then
    SSH_CMD="ssh -T -q -l $USER lander.monsoon-metoffice.co.uk ssh -T xcs"
else
  echo "ERROR: $MACHINE is an invalid machine; valid options are: `echo ${MACHINES[@]} | sed 's/ /, /g'`.">&2 && exit;
fi

$VERBOSE || $TEST && echo "MACHINE=$MACHINE"
$VERBOSE || $TEST && echo "SSH_CMD=$SSH_CMD"
$VERBOSE || $TEST && echo "SUITE=$SUITE"

############
# do stuff #
############

# note how variables defined inside heredocs & herestrings are escaped 
# (as per https://unix.stackexchange.com/a/405254/177464)

$SSH_CMD << EOF

  ###########################
  # get some more info      #
  # and do some more checks #
  ###########################

  # check suite exists...
  if [[ -z "$REMOTE_DIR" ]]; then
    SUITE_DIR="\$HOME/cylc-run/$SUITE"
  else
    SUITE_DIR="$REMOTE_DIR"
  fi  
  if [ ! -d \$SUITE_DIR ]; then
    echo "ERROR: unable to find suite '\$SUITE_DIR' (@\$(hostname))" >&2 && exit;
  fi

  # check cycle exists...
  if [[ -z "$CYCLE" ]]; then
    CYCLE_DIR=\$(ls -d \$SUITE_DIR/work/*/ 2>/dev/null | egrep '[0-9]{8}T[0-9]{4}[A-Z]/$' | tail -1)
    if [ ! -d \$CYCLE_DIR ]; then
      echo "ERROR: unable to find latest cycle for '$SUITE' (@\$(hostname))" >&2 && exit;
    fi
  else
    CYCLE_DIR="\$SUITE_DIR/work/\$CYCLE"
    if [ ! -d \$CYCLE_DIR ]; then
      echo "ERROR: unable to find cycle '\$CYCLE_DIR' (@\$(hostname))" >&2 && exit;
    fi
  fi

  # get the cycle details...
  CYCLE=\$(basename \$CYCLE_DIR)
  [[ \$CYCLE =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{4}[A-Z]{1}).*$ ]]
  CYCLE_YEAR="\${BASH_REMATCH[1]}"
  CYCLE_MONTH="\${BASH_REMATCH[2]}"
  CYCLE_DAY="\${BASH_REMATCH[3]}"
  CYCLE_TIME="\${BASH_REMATCH[4]}"

  # get the previous cycle...
  while read CURRENT_CYCLE_DIR; do
    if [[ "\$(basename \$CURRENT_CYCLE_DIR)" == "\$CYCLE" ]]; then
      break;
    fi
    PREV_CYCLE_DIR=\$CURRENT_CYCLE_DIR
    PREV_CYCLE=\$(basename \$PREV_CYCLE_DIR)
  done <<< "\$(ls -d \$SUITE_DIR/work/*/)"

  $VERBOSE || $TEST && echo "SUITE_DIR=\$SUITE_DIR"
  $VERBOSE || $TEST && echo "CYCLE=\$CYCLE"
  $VERBOSE || $TEST && echo "CYCLE_DIR=\$CYCLE_DIR"
  $VERBOSE || $TEST && echo "PREV_CYCLE=\$PREV_CYCLE"
  $VERBOSE || $TEST && echo "PREV_CYCLE_DIR=\$PREV_CYCLE_DIR"

  ############
  # UM stuff #
  ############

  DATA_DIR_UM="\$SUITE_DIR/share/data/History_Data"
  mkdir \$DATA_DIR_UM/tmp 2>/dev/null

  # find the appropriate dump...
  # get rid of any later dumps...
  while read DUMP; do
    DUMP_NAME=\$(basename \$DUMP)
    [[ \$DUMP_NAME =~ ^.*${SUITE_BASE}.*([0-9]{4})([0-9]{2})([0-9]{2})_[0-9]{2}$ ]]
    DUMP_YEAR="\${BASH_REMATCH[1]}"
    DUMP_MONTH="\${BASH_REMATCH[2]}"
    DUMP_DAY="\${BASH_REMATCH[3]}"
    if [ "\$DUMP_YEAR\$DUMP_MONTH\$DUMP_DAY" -eq "\$CYCLE_YEAR\$CYCLE_MONTH\$CYCLE_DAY" ]; then
      RESTART_DUMP_UM=\$DUMP
      $VERBOSE || $TEST && echo "UM restart dump=\$DUMP"
    elif [ "\$DUMP_YEAR\$DUMP_MONTH\$DUMP_DAY" -gt "\$CYCLE_YEAR\$CYCLE_MONTH\$CYCLE_DAY" ]; then
      $TEST || mv \$DUMP \$DATA_DIR_UM/tmp
      $VERBOSE || $TEST && echo "getting rid of later UM restart dump \$DUMP"
    else
      $TEST && echo "ignoring earlier UM restart dump \$DUMP"
    fi
  done <<< "\$(find \$DATA_DIR_UM -maxdepth 1 -regextype posix-extended -regex "^\$DATA_DIR_UM/${SUITE_BASE}.*[0-9]{8}_[0-9]{2}$" -type f)"

  if [ -z "\$RESTART_DUMP_UM" ]; then
    echo "ERROR: unable to find a suitable UM restart dump" >&2 && exit
  fi

  # replace the history file...
  $TEST || mv "\$DATA_DIR_UM/$SUITE_BASE.xhist" \$DATA_DIR_UM/tmp
  PREV_HISTORY=\$(ls \$PREV_CYCLE_DIR/coupled/history_archive/temp_hist.* | tail -1)
  FUTURE_DUMP=\$(grep CHECKPOINT_DUMP_IM \$PREV_HISTORY | awk '{print \$4}')
  if [[ \$FUTURE_DUMP =~ \$PREV_HISTORY ]]; then
    echo "ERROR: UM history file does not point to the appropriate restart dump" >&2 && exit 
  fi
  cp \$PREV_HISTORY \$DATA_DIR_UM/$SUITE_BASE.xhist
  $VERBOSE || $TEST && echo "setting history file to \$PREV_HISTORY"

  # perturb the dump...
  $VERBOSE || $TEST && echo "perturbing the dump (this may take a while)..."
  if [ $MACHINE == "NEXCS" ]; then 
    $TEST || /home/d05/hadom/Var/random_temp_perturb_seed_cray \$RESTART_DUMP_UM \$RESTART_DUMP_UM.pert
    $TEST && echo "/home/d05/hadom/Var/random_temp_perturb_seed_cray \$RESTART_DUMP_UM \$RESTART_DUMP_UM.pert"
  elif [ $MACHINE == "ARCHER" ]; then
    $TEST || module load anaconda
    $TEST && echo "module load anaconda"
    $TEST || export PYTHONPATH=\${PYTHONPATH=}:/work/y07/y07/umshared/mule/mule-2017.08.1/python2.7/lib
    $TEST && echo "export PYTHONPATH=\${PYTHONPATH=}:/work/y07/y07/umshared/mule/mule-2017.08.1/python2.7/lib"
    $TEST || python2.7 /home/n02/shared/mjrobe/perturb_theta.py --output \$RESTART_DUMP_UM.pert \$RESTART_DUMP_UM
    $TEST && echo "python2.7 /home/n02/shared/mjrobe/perturb_theta.py --output \$RESTART_DUMP_UM.pert \$RESTART_DUMP_UM"
  fi
  $TEST || mv \$RESTART_DUMP_UM \$RESTART_DUMP_UM.orig
  $TEST && echo "mv \$RESTART_DUMP_UM \$RESTART_DUMP_UM.orig"
  $TEST || ln -s \$RESTART_DUMP_UM.pert \$RESTART_DUMP_UM
  $TEST && echo "ln -s \$RESTART_DUMP_UM.pert \$RESTART_DUMP_UM"

  ##############
  # NEMO stuff #
  ##############

  DATA_DIR_NEMO="\$SUITE_DIR/share/data/History_Data/NEMOhist"
  mkdir \$DATA_DIR_NEMO/tmp 2>/dev/null

  # find the appropriate dumps...
  # get rid of any later dumps...
  while read DUMP; do
    DUMP_NAME=\$(basename \$DUMP)
    [[ \$DUMP_NAME =~ ^.*_([0-9]{4})([0-9]{2})([0-9]{2})_.*\.nc$ ]]
    DUMP_YEAR="\${BASH_REMATCH[1]}"
    DUMP_MONTH="\${BASH_REMATCH[2]}"
    DUMP_DAY="\${BASH_REMATCH[3]}"
    if [ "\$DUMP_YEAR\$DUMP_MONTH\$DUMP_DAY" -eq "\$CYCLE_YEAR\$CYCLE_MONTH\$CYCLE_DAY" ]; then
      RESTART_DUMP_NEMO=\$DUMP
      $VERBOSE || $TEST && echo "NEMO restart dump=\$DUMP"
    elif [ "\$DUMP_YEAR\$DUMP_MONTH\$DUMP_DAY" -gt "\$CYCLE_YEAR\$CYCLE_MONTH\$CYCLE_DAY" ]; then
      $TEST || mv \$DUMP \$DATA_DIR_NEMO/tmp
      $VERBOSE || $TEST && echo "getting rid of later NEMO restart dump \$DUMP"
    else
      $TEST && echo "ignoring earlier NEMO restart dump \$DUMP"
    fi
  done <<< "\$(find \$DATA_DIR_NEMO -maxdepth 1 -regextype posix-extended -regex "^\$DATA_DIR_NEMO/${SUITE_BASE}o_.*[0-9]{8}_restart.*$" -type f)"

  if [ -z "\$RESTART_DUMP_NEMO" ]; then
    echo "ERROR: unable to find any suitable NEMO restart dumps" >&2 && exit
  fi

  ##############
  # CICE stuff #
  ##############

  DATA_DIR_CICE="\$SUITE_DIR/share/data/History_Data/CICEhist"
  mkdir \$DATA_DIR_CICE/tmp 2>/dev/null

  # find the appropriate dump...
  # get rid of any later dumps...
  while read DUMP; do
    DUMP_NAME=\$(basename \$DUMP)
    [[ \$DUMP_NAME =~ ^.*\.restart\.([0-9]{4})-([0-9]{2})-([0-9]{2})-[0-9]+\.nc$ ]]
    DUMP_YEAR="\${BASH_REMATCH[1]}"
    DUMP_MONTH="\${BASH_REMATCH[2]}"
    DUMP_DAY="\${BASH_REMATCH[3]}"
    if [ "\$DUMP_YEAR\$DUMP_MONTH\$DUMP_DAY" -eq "\$CYCLE_YEAR\$CYCLE_MONTH\$CYCLE_DAY" ]; then
      RESTART_DUMP_CICE=\$DUMP
      $VERBOSE || $TEST && echo "CICE restart dump=\$DUMP"
    elif [ "\$DUMP_YEAR\$DUMP_MONTH\$DUMP_DAY" -gt "\$CYCLE_YEAR\$CYCLE_MONTH\$CYCLE_DAY" ]; then
      $TEST || mv \$DUMP \$DATA_DIR_CICE/tmp
      $VERBOSE || $TEST && echo "getting rid of later CICE restart dump \$DUMP"
    else
      $TEST && echo "ignoring earlier CICE restart dump \$DUMP"
    fi
 done <<< "\$(find \$DATA_DIR_CICE -maxdepth 1 -regextype posix-extended -regex "^\$DATA_DIR_CICE/${SUITE_BASE}i\.restart\..*\.nc$" -type f)"

  if [ -z "\$RESTART_DUMP_CICE" ]; then
    echo "ERROR: unable to find a suitable CICE restart dump" >&2 && exit
  fi

  # point the restart file to the appropirate restart dump...
  $TEST || cp "\$DATA_DIR_CICE/ice.restart_file" "\$DATA_DIR_CICE/ice.restart_file.orig"
  $TEST && echo "cp '\$DATA_DIR_CICE/ice.restart_file' '\$DATA_DIR_CICE/ice.restart_file.orig'"
  $TEST || echo \$RESTART_DUMP_CICE > "\$DATA_DIR_CICE/ice.restart_file"
  $TEST && echo "echo \$RESTART_DUMP_CICE > '\$DATA_DIR_CICE/ice.restart_file'"

  #######################
  # hooray, you're done #
  #######################

  echo -e "\nnow re-submit the job: rose suite-run [--no-gcontrol] --restart --config=\$HOME/roses/$SUITE"

EOF

#######################
# hooray, you're done #
#######################

exit
 
