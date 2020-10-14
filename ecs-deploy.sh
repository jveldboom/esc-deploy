#!/usr/bin/env bash

#######################################################################
# This script performs deployment of ECS Service using AWS CodeDeploy
#
# Heavily inspired by https://github.com/silinternational/ecs-deploy
# and https://gist.github.com/antonbabenko/632b54e8e488b9f48d016238792a9193
#
# Hacked on by: John Veldboom
#######################################################################

set -e
#set -x

####################################################################
# DO NOT TOUCH BELOW THIS LINE if you don't know what you are doing
####################################################################

APPSPEC_FILENAME="appspec_ecs.yaml"
APPSPEC_FILE=false

TASK_DEF_FILENAME="task_def.json"
TASK_DEFINITION_FILE=false

function print_usage {
  echo
  echo "Usage: ecs-deploy [OPTIONS]"
  echo
  echo "Required arguments:"
  echo
  echo -e "  --cluster\t\t\tName of ECS Cluster"
  echo -e "  --service\t\t\tName of ECS Service to update"
  echo -e "  --image\t\t\tImage ID to deploy (eg, 123456789000.dkr.ecr.us-east-1.amazonaws.com/backend:v1.2.3)"
  echo -e "  --codedeploy-application\t\tName of CodeDeploy Application"
  echo -e "  --codedeploy-deployment-group\t\tName of CodeDeploy Deployment Group"
  echo -e "  --container-port\t\tContainer Port Number"
  echo
  echo "Optional arguments:"
  echo
  echo -e "  --task-definition-file\tLocal task definition file to use"
  echo -e "  --appspec-file\t\tLocal AppSpec file to use"
  echo
  echo "Example with all arguments:"
  echo
  echo "  ecs-deploy \\"
  echo "    --cluster production \\"
  echo "    --service backend \\"
  echo "    --container-port 3000 \\"
  echo "    --codedeploy-application backend_app  \\"
  echo "    --codedeploy-deployment-group backend_app_dg \\"
  echo "    --image 123456789000.dkr.ecr.us-east-1.amazonaws.com/api:1.2.0 \\"
  echo "    --appspec-file appspec.yaml \\"
  echo "    --task-definition-file task-definition.json"
  echo
}

function assert_not_empty {
  local readonly arg_name="$1"
  local readonly arg_value="$2"

  if [[ -z "$arg_value" ]]; then
    echo "ERROR: The value for '$arg_name' cannot be empty"
    print_usage
    exit 1
  fi
}

function assert_is_installed {
  local readonly name="$1"

  if [[ ! $(command -v ${name}) ]]; then
    echo "ERROR: The binary '$name' is required by this script but is not installed or in the system's PATH."
    exit 1
  fi
}

function get_current_task_definition() {
  TASK_DEFINITION_ARN=$(aws ecs describe-services --services "$service" --cluster "$cluster" | jq -r ".services[0].taskDefinition")
  TASK_DEFINITION=$(aws ecs describe-task-definition --task-definition "$TASK_DEFINITION_ARN")
}

function create_new_task_def_json() {
  DEF=$(echo "$TASK_DEFINITION" | jq -r ".taskDefinition.containerDefinitions[].image=\"$image\"" | jq -r ".taskDefinition")

  # Default JQ filter for new task definition
  NEW_DEF_JQ_FILTER="executionRoleArn: .executionRoleArn, family: .family, volumes: .volumes, containerDefinitions: .containerDefinitions, placementConstraints: .placementConstraints"

  # Some options in task definition should only be included in new definition if present in
  # current definition. If found in current definition, append to JQ filter.
  CONDITIONAL_OPTIONS=(networkMode taskRoleArn placementConstraints)
  for i in "${CONDITIONAL_OPTIONS[@]}"; do
    re=".*${i}.*"
    if [[ "$DEF" =~ $re ]]; then
      NEW_DEF_JQ_FILTER="${NEW_DEF_JQ_FILTER}, ${i}: .${i}"
    fi
  done

  # Updated jq filters for AWS Fargate
  REQUIRES_COMPATIBILITIES=$(echo "${DEF}" | jq -r ". | select(.requiresCompatibilities != null) | .requiresCompatibilities[]")
  if [[ "${REQUIRES_COMPATIBILITIES}" == 'FARGATE' ]]; then
    FARGATE_JQ_FILTER='executionRoleArn: .executionRoleArn, requiresCompatibilities: .requiresCompatibilities, cpu: .cpu, memory: .memory'
    NEW_DEF_JQ_FILTER="${NEW_DEF_JQ_FILTER}, ${FARGATE_JQ_FILTER}"
  fi

  # Build new DEF with jq filter
  NEW_TASK_DEF=$(echo "$DEF" | jq "{${NEW_DEF_JQ_FILTER}}")

  # If in test mode output $NEW_TASK_DEF
  if [ "$BASH_SOURCE" != "$0" ]; then
    echo "$NEW_TASK_DEF"
  fi
}

function create_task_def_file() {
  echo "$NEW_TASK_DEF" > $TASK_DEF_FILENAME
}

function create_app_spec_file() {
  container_name=$(echo "$NEW_TASK_DEF" | jq -r ".containerDefinitions[].name")
  echo "---
version: 1
Resources:
- TargetService:
    Type: AWS::ECS::Service
    Properties:
      TaskDefinition: PlaceholderForTaskDefinition
      LoadBalancerInfo:
        ContainerName: ${container_name}
        ContainerPort: ${container_port}
      PlatformVersion: "1.4.0"
" > $APPSPEC_FILENAME
}

function ecs_deploy_service() {
  aws ecs deploy \
    --cluster "$cluster" \
    --service "$service" \
    --task-definition "$TASK_DEF_FILENAME" \
    --codedeploy-appspec "$APPSPEC_FILENAME" \
    --codedeploy-application "$codedeploy_application" \
    --codedeploy-deployment-group "$codedeploy_deployment_group"
}

function ecs_deploy {
  assert_is_installed "jq"

  local cluster=""
  local service=""
  local image=""
  local iam_role=""

  while [[ $# > 0 ]]; do
    local key="$1"

    case "$key" in
      --iam-role)
        iam_role="$2"
        shift
        ;;
      --cluster)
        cluster="$2"
        shift
        ;;
      --service)
        service="$2"
        shift
        ;;
      --codedeploy-application)
        codedeploy_application="$2"
        shift
        ;;
      --codedeploy-deployment-group)
        codedeploy_deployment_group="$2"
        shift
        ;;
      --image)
        image="$2"
        shift
        ;;
      --container-port)
        container_port="$2"
        shift
        ;;
      --task-definition-file)
        TASK_DEFINITION_FILE="$2"
        shift
        ;;
      --appspec-file)
        APPSPEC_FILE="$2"
        shift
        ;;
      --help)
        print_usage
        exit
        ;;
      *)
        echo "ERROR: Unrecognized argument: $key"
        print_usage
        exit 1
        ;;
    esac

    shift
  done

  assert_not_empty "--cluster" "$cluster"
  assert_not_empty "--service" "$service"
  assert_not_empty "--image" "$image"
  assert_not_empty "--codedeploy-application" "$codedeploy_application"
  assert_not_empty "--codedeploy-deployment-group" "$codedeploy_deployment_group"
  assert_not_empty "--container-port" "$container_port"

  echo "Cluster: $cluster"
  echo "Service: $service"
  echo "Image: $image"
  echo

  # Dynamically get task definition or read it from local file
  if [ $TASK_DEFINITION_FILE == false ]; then
    echo "Getting latest task definition for the service $service"
    get_current_task_definition

    echo "Task definition ARN: $TASK_DEFINITION_ARN"
    echo

    echo "Create new task definition"
    create_new_task_def_json
    echo "Created"
    echo

    echo "Create file $TASK_DEF_FILENAME"
    create_task_def_file
    echo "Created"
    echo
  else
    echo "Using local task definition '$TASK_DEFINITION_FILE' for the service $service"
    TASK_DEF_FILENAME=$TASK_DEFINITION_FILE
    NEW_TASK_DEF=`cat $TASK_DEF_FILENAME`
  fi

  # Create AppSpec file or use local file
  if [ $APPSPEC_FILE == false ]; then
    echo "Create file $APPSPEC_FILENAME"
    create_app_spec_file
    echo "Created"
    echo
  else
    echo "Using local appspec file '$APPSPEC_FILE'"
    APPSPEC_FILENAME=$APPSPEC_FILE
  fi

  echo "Deploy ECS service"
  ecs_deploy_service
  echo "Done!"

}

ecs_deploy "$@"
