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

# Script is called by cron each week, Saturday at 00:00
# It can be also run manually in case of priority events
# Updates budgets.csv in its same folder

# settings -------------------------------------------------------------------

BU_INSTANCE_TAG="BusinessUnit"
SINGLE_CORE_WEEKLY_COST=23.6880  # r5.large weekly on-demand cost in eu-west-1

# ----------------------------------------------------------------------------

COMMAND=$(readlink -f "$0")
CWD=$(dirname "${COMMAND}")

# if anything fails, echo 0 to disable any job run  
exit_error() {
    exit 1
}
trap 'exit_error' ERR

# dump any error in log file
exec 2>>/var/log/budget.control.updater.log

# get budget.conf settings
budgets_conf=$(cat "${CWD}"/budget.control.conf | sed '/^#/d;/^$/d')

# build Cost Explorer query
now=$(date +'%Y-%m-%d %H:%M:%S')
today=$(date +'%Y-%m-%d')
last_week=$(date --date="7 days ago" +'%Y-%m-%d')

echo "[${now}] Starting budget control update..." >> /var/log/budget.control.updater.log

# loop over business units
new_entry="${today}"
oldIFS=${IFS}
IFS=$'\n'
for budget_entry in ${budgets_conf}; do

    # business unit identifier
    _BU=$(echo "${budget_entry}" | sed 's/^\([^,]*\),\([^,]*\)$/\1/')
    # business unit budget
    _BUDGET=$(echo "${budget_entry}" | sed 's/^\([^,]*\),\([^,]*\)$/\2/')
    
    # Cost Explorer query execution
    _ce_response=$(aws ce get-cost-and-usage \
        --time-period Start=${last_week},End=${today} \
        --granularity DAILY \
        --metrics "BlendedCost" "UnblendedCost" "UsageQuantity" \
        --filter \
            '{
                "And": [
                    { "Dimensions" : {
                            "Key" : "USAGE_TYPE_GROUP",
                            "Values" : [ "EC2: Running Hours" ]
                        }
                    },
                    { "Tags": {
                            "Key": "'${BU_INSTANCE_TAG}'", 
                            "Values": [ "'${_BU}'" ]
                        } 
                    }
                ]
            }' \
        --output json 
    )

    # business unit last week cost
    _WEEK_COST=$(echo "${_ce_response}" \
        | jq -r '[ .ResultsByTime[].Total | 
        .UnblendedCost.Amount,.BlendedCost.Amount,.UsageQuantity.Amount 
        | tonumber ] | add'
    )

    # calculate cores limit from budget and single core weekly cost
    _THEORETICAL_CORE_LIMIT=$(echo "${_BUDGET} / ${SINGLE_CORE_WEEKLY_COST}" | bc)

    # round the values
    _WEEK_COST=$(printf "%.0f" $(echo "${_WEEK_COST}"))

    # calculate adjusted core limit accordingly to last week cost
    if (( ${_WEEK_COST} <= ${_BUDGET} )); then
        _ADJUSTED_CORE_LIMIT=${_THEORETICAL_CORE_LIMIT}
    else
        _ADJUSTED_CORE_LIMIT=$(echo "${_THEORETICAL_CORE_LIMIT} * ${_BUDGET} / ${_WEEK_COST}" | bc)
    fi

    # add calculated values to new CSV entry
    _ADJUSTED_CORE_LIMIT=$(printf "%.0f" $(echo "${_ADJUSTED_CORE_LIMIT}"))
    new_entry="${new_entry},${_BU},${_WEEK_COST},${_BUDGET},${_ADJUSTED_CORE_LIMIT}"
done
IFS=${oldIFS}

# add the new entry to budget.control.csv
echo "${new_entry}" >> "${CWD}"/budget.control.csv

now=$(date +'%Y-%m-%d %H:%M:%S')
echo "[${now}] Ending budget control update" >> /var/log/budget.control.updater.log
