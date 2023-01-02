#!/bin/bash

# (C) 2022  Amazon Web Services, Inc. or its affiliates.  All Rights Reserved.
# This  AWS Content  is provided  subject  to the  terms of  the AWS  Customer
# Agreement  available  at  http://aws.amazon.com/agreement or  other  written
# agreement between Customer and Amazon  Web Services, Inc.; provided that AWS
# grants  Customer a  worldwide, royalty-free,  non-exclusive, nontransferable
# license to use, reproduce, display, perform, and prepare derivative works of
# this  AWS Content.  Except as  provided  herein, Customer  obtains no  other
# rights from  AWS, its affiliates,  or their  licensors to this  AWS Content,
# including without  limitation any related intellectual  property rights. AWS
# will be the  exclusive owner of any modifications to  or derivative works of
# this AWS  Content. Customer acknowledges  that this AWS Content  is provided
# "as is" without  representations or warranties of any  kind. Customer is
# solely responsible  for testing, deploying, maintaining  and supporting this
# AWS Content and for determining the  suitability of this AWS Content for its
# business purposes.

# script is called by PBS scheduler process
# usage: budget.control.dyn_res.sh <BU>
# returns the number of available cores for business unit BU, according to its
# budget

# settings -------------------------------------------------------------------

BU_INSTANCE_TAG="BusinessUnit"

# ----------------------------------------------------------------------------

BU=$1
COMMAND=$(readlink -f "$0")
CWD=$(dirname "${COMMAND}")

# if anything fails, echo 0 to disable new jobs runs  
exit_error() {
    # TBC add mail notification about the failure
    echo 0
    exit
}
trap 'exit_error' ERR

# dump any error in log file
exec 2>>/var/log/budget.control.dyn_res.log

# read last line from budgets.csv
last_line=$(cat "${CWD}"/budget.control.csv | sed '/^#/d;/^$/d' | sed '$!d')
[ -z "${last_line}" ] && exit_error

# retrieve the used/busy cores from ec2 instances with the above tag
CORE_COUNT=$(/usr/local/bin/aws ec2 describe-instances \
    --filters Name=instance-state-name,Values=running Name=tag:"${BU_INSTANCE_TAG}",Values="${BU}" \
    --no-paginate  \
    --output json \
    | jq -r '[ .Reservations[].Instances[] | .CpuOptions.CoreCount ] | add'
)
[ -z "${CORE_COUNT}" ] && exit_error

BU_CORE_LIMIT=$(echo "${last_line}" | sed "s/^.*,${BU},[0-9][0-9]*,[0-9][0-9]*,\([0-9][0-9]*\).*$/\1/")
[ -z "${BU_CORE_LIMIT}" ] && exit_error

# return the amount of available/free cores
if (( ${CORE_COUNT} >= ${BU_CORE_LIMIT} )); then
    AVAILABLE_CORES=0
else
    AVAILABLE_CORES=$(( ${BU_CORE_LIMIT} - ${CORE_COUNT} ))
fi

echo ${AVAILABLE_CORES}
