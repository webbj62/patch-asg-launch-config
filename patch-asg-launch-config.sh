#!/bin/bash
#############################################################################
# Name: patch-asg-launch-config.sh
# Date: 14 October 2020
# Version: 1.0
# Description: Update AMI for AWS Autoscaling Group
# Created By: John H. Webb
#############################################################################

umask 022
ASG_NAME=""
PROFILE_NAME=""
AWS_REGION=""
AMI_ID=""
DATETODAY=$(date +%Y%m%d)

function usage()
{
    echo -e "\n\t $0"
    echo ""
    echo -e "\t -h --help"
    echo -e "\t -g --auto-scale-group=ASG_NAME"
    echo -e "\t -p --profile=PROFILE_NAME"
    echo -e "\t -r --region=AWS_REGION"
    echo -e "\t -a --ami=AMI_ID"
    echo ""
}

# Check if user is authenicated to AWS
echo ""
aws sts get-caller-identity > /dev/null 2>&1
if [ $? -eq 0 ]; then
  echo -e "....User already authenicated to AWS account"
else
  echo -e "\nFAILED: User need to be authenicated to AWS before executing this script."
  exit 1
fi

# Make all arguments were passed
if [ "$#" -ne 4 ]; then
    usage
    exit 1
fi

while [ "$1" != "" ]; do
    PARAM=`echo $1 | awk -F= '{print $1}'`
    VALUE=`echo $1 | awk -F= '{print $2}'`
    case $PARAM in
        -h | --help)
            usage
            exit 1
            ;;
        -g | --auto-scale-group)
            ASG_NAME=$VALUE
            ;;
        -p | --profile)
            PROFILE_NAME=$VALUE
            ;;
        -r | --region)
            AWS_REGION=$VALUE
            ;;
        -a | --ami)
            AMI_ID=$VALUE
            ;;
        *)
            echo "ERROR: unknown parameter \"$PARAM\""
            usage
            exit 1
            ;;
    esac
    shift
done

echo ""
echo "....Patching Autoscaling Group: $ASG_NAME"

LC_NAME=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names $ASG_NAME --query 'AutoScalingGroups[0].LaunchConfigurationName' --profile "$PROFILE_NAME" --region "$AWS_REGION" | sed -e 's/^"//' -e 's/"$//')
echo "....Current ASG Launch Configuration: $LC_NAME"
NEW_LC_NAME="$(echo $LC_NAME | awk -F- 'sub(FS $NF,x)')"-"$DATETODAY"
echo "....New ASG Launch Configuration: $NEW_LC_NAME"

echo ""
echo "....Capturing current Launch Configuration"
aws autoscaling describe-launch-configurations --launch-configuration-names "$LC_NAME" --output json --query 'LaunchConfigurations[0]' --profile "$PROFILE_NAME" --region "$AWS_REGION" > "$LC_NAME".json

echo "....Updating new Launch Configuration with AMI: $AMI_ID"
cat "$LC_NAME".json | \
jq 'walk(if type == "object" then with_entries(select(.value != null and .value != "" and .value != [] and .value != {} and .value != [""] )) else . end )' | \
jq 'del(.CreatedTime, .LaunchConfigurationARN, .BlockDeviceMappings)' | \
jq ".ImageId = \"$AMI_ID\" | .LaunchConfigurationName = \"$NEW_LC_NAME\"" > "$NEW_LC_NAME".json

echo "....Creating new Launch Configuration with AMI: $AMI_ID"
if [ -z "$(jq .UserData $LC_NAME.json --raw-output)" ]; then
     aws autoscaling create-launch-configuration --cli-input-json file://"$NEW_LC_NAME".json --profile "$PROFILE_NAME" --region "$AWS_REGION"
else
     aws autoscaling create-launch-configuration --cli-input-json file://"$NEW_LC_NAME".json --user-data file://<(jq .UserData "$NEW_LC_NAME".json --raw-output | base64 --decode) --profile "$PROFILE_NAME" --region "$AWS_REGION"
fi

echo "....Updating $ASG_NAME ASG with Launch Configuration: $NEW_LC_NAME"
aws autoscaling update-auto-scaling-group --auto-scaling-group-name "$ASG_NAME" --launch-configuration-name "$NEW_LC_NAME" --profile "$PROFILE_NAME" --region "$AWS_REGION"

echo "....Starting $ASG_NAME ASG Instance Refresh"
REFRESH_ID=$(aws autoscaling start-instance-refresh --auto-scaling-group-name "$ASG_NAME" --preferences '{"InstanceWarmup": 900, "MinHealthyPercentage": 75}' --profile "$PROFILE_NAME" --region "$AWS_REGION" | jq '.InstanceRefreshId' | sed -e 's/^"//' -e 's/"$//')

echo "....Cleaning up launch configuration files"
rm -f "$LC_NAME.json" > /dev/null
rm -f "$NEW_LC_NAME.json" > /dev/null

echo ""
echo "Old Launch Configuration Name: $LC_NAME"
echo "New Launch Configuration Name: $NEW_LC_NAME"
echo "ASG Instance Refresh Status ID: $REFRESH_ID"

REFRESH_STATUS=$(aws autoscaling describe-instance-refreshes --auto-scaling-group-name "$ASG_NAME" --profile "$PROFILE_NAME" --region "$AWS_REGION --instance-refresh-ids "$REFRESH_ID" | jq '.InstanceRefreshes[0].Status' | sed -e 's/^"//' -e 's/"$//')