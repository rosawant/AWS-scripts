#!/bin/bash
#########################################
##### @Maintainer: Roshan Sawant ########
#########################################
TASKDEF_TEMPLATE="$1"
REVISION="$2"
# The cluster name should be 'namespaced' using the stack/cell name as the prefix. Thus, if stack name of 'test' is provided
# with cluster name of 'microservices', then the resulting cluster name will be 'test-microservices'.
ECS_CLUSTER_NAME="$3"
ECS_SERVICE_NAME="$4"
STACK_NAME="${5:-qa}"
SECURE_BUCKET_NAME="$6"
AWS_LOG_GROUPS="$7"
SMX_DB_PROPS="$8"
REGION="${9:-us-east-1}"
DOCKER_IMAGE_NAME="${10}"
SMX_SECURITY_PROPS="${11}"

ELB_TAGNAME="resource-name"

NEW_SERVICE_LB=""


[[ $(aws configure --profile ${STACK_NAME} list) && $? -eq 0 ]] && AWS_PROFILE_ARG="--profile $STACK_NAME" || AWS_PROFILE_ARG="--profile default" ]]

ECS_CONTAINER_INSTANCES="0"
ECS_ORIGINAL_TASK_COUNT="1"
ECS_NEW_TASK_COUNT="1"
THISDIR=$(dirname $0)
TASKDEF_TMP_FILENAME="${THISDIR}/${STACK_NAME}-${ECS_SERVICE_NAME}-${REVISION}-tmp.json"
TASKDEF_FILENAME="${THISDIR}/${STACK_NAME}-${ECS_SERVICE_NAME}-${REVISION}-task.json"

prepareTaskDefinition(){
    TASKDEF=$1

    #Set the CloudWatch Logs region based on the target region
    echo "REGION: ${REGION}"
    TASKDEF="$(echo "${TASKDEF}" | jq --arg region ${REGION} '.containerDefinitions[].logConfiguration.options."awslogs-region" = $region')"
    TASKDEF="$(echo "${TASKDEF}" | jq '.containerDefinitions[0].environment |= del(.[] | select(.name == "smx_props"))')"
    TASKDEF="$(echo "${TASKDEF}" | jq '.containerDefinitions[0].environment |= del(.[] | select(.name == "smx_json_props"))')"
    TASKDEF="$(echo "${TASKDEF}" | jq --arg stack "${STACK_NAME}" '.containerDefinitions[0].environment |= . + [{ "name": "STACK_NAME", "value" : $stack
 }]')"

    echo "SECURE_BUCKET_NAME: ${SECURE_BUCKET_NAME}"
    # Update environment variable for secure bucket
    if [ -n "${SECURE_BUCKET_NAME}" ]
    then
        SMX_PROPS="s3://${SECURE_BUCKET_NAME}/config.properties"
        echo "SMX_PROPS: ${SMX_PROPS}"
        #SMX_DB_PROPS="s3://${SECURE_BUCKET_NAME}/multischema.json"
        SMX_DB_PROPS="ps:/${SMX_DB_PROPS}"
        echo "SSMX_DB_PROPS: ${SMX_DB_PROPS}"
        SMX_SECURITY_PROPS="ps:/${SMX_SECURITY_PROPS}"
        echo "SSMX_DB_PROPS: ${SMX_DB_PROPS}"
        TASKDEF="$(echo "${TASKDEF}" | jq --arg props "${SMX_PROPS}" '.containerDefinitions[0].environment |= . + [{ "name": "smx_props", "value" : $props }]
')"
        TASKDEF="$(echo "${TASKDEF}" | jq --arg props "${SMX_DB_PROPS}" '.containerDefinitions[0].environment |= . + [{ "name": "smx_json_props", "value" : $
props }]')"
        TASKDEF="$(echo "${TASKDEF}" | jq --arg props "${SMX_SECURITY_PROPS}" '.containerDefinitions[0].environment |= . + [{ "name": "smx_security_props", "
value" : $props }]')"

    else
        echo "ERROR: S3SecureConfigBucket missing"
        exit 1
    fi

    echo "${TASKDEF}" > ${TASKDEF_FILENAME}
}

updateCloudWatchLogs(){
      #AWS_LOG_GROUPS="$(jq -r '.containerDefinitions[].logConfiguration.options["awslogs-group"] | select (.!=null)' ${TASKDEF_FILENAME})"
      #AWS_LOG_REGION="$(jq -r '.containerDefinitions[].logConfiguration.options["awslogs-region"] | select (.!=null)' ${TASKDEF_FILENAME}|uniq)"
      AWS_LOG_GROUPS=${AWS_LOG_GROUPS}
      AWS_LOG_REGION=${REGION}
      AWS_LOG_GROUP_ARRAY=($AWS_LOG_GROUPS)
      echo "${AWS_LOG_GROUP_ARRAY[*]}"
      for AWS_LOG_GROUP in "${AWS_LOG_GROUP_ARRAY[@]}"
      do
         if [ -n "${AWS_LOG_GROUP}" ] && [ -n "${AWS_LOG_REGION}" ]
         then
           AWS_LOG_GROUP_MATCHES="$(aws logs describe-log-groups ${AWS_PROFILE_ARG} --log-group-name-prefix ${AWS_LOG_GROUP} | jq '.logGroups | length')"

        if [ "${AWS_LOG_GROUP_MATCHES}" == "0" ]
        then
          #TODO: add retention policy for every new creation of log group
#          aws logs put-retention-policy ${AWS_PROFILE_ARG} --log-group-name "${AWS_LOG_GROUP}" --retention-in-days $QA_RET
          echo "Create missing log group ${AWS_LOG_GROUP} in AWS region ${AWS_LOG_REGION}"
          aws logs create-log-group ${AWS_PROFILE_ARG} --region ${AWS_LOG_REGION} --log-group-name "${AWS_LOG_GROUP}"
        fi
        else
        echo "WARNING: No valid logging configuration could be found in the ECS Task Definition."
        fi
      done
}

waitForStableService() {
  for i in {1..5}; do
    echo "Waiting for ${ECS_SERVICE_NAME} to stabilize... (attempt ${i} of 5)"
    aws ecs wait services-stable ${AWS_PROFILE_ARG} --cluster ${ECS_CLUSTER_NAME} --services ${ECS_SERVICE_NAME} && break
    if [ "${i}" == "5" ]; then
                echo "Service ${ECS_SERVICE_NAME} failed to stabilize. Exiting."
                if [ -f "${TASKDEF_FILENAME}" ]; then rm ${TASKDEF_FILENAME}; fi
                exit 1
        fi
  done
  echo "Service ${ECS_SERVICE_NAME} is stable."
}

if [ ! -z "$1" ] && [ ! -z "$2" ] && [ ! -z "$3" ] && [ ! -z "$4" ]
then
   cp ${TASKDEF_TEMPLATE} ${TASKDEF_TMP_FILENAME}
   sed -e "s;%DOCKER_TAG%;${REVISION};g" ${TASKDEF_TMP_FILENAME} | sed -e "s;%DOCKER_IMAGE_NAME_TAG%;${DOCKER_IMAGE_NAME};g" | sed -e "s;%STACK%;${ECS_SERVIC
E_NAME};g" | sed -e "s;%AWS_LOG_GROUP%;${AWS_LOG_GROUPS};g" |sed -e "s;%REGION%;${AWS_LOG_REGION};g" > ${TASKDEF_FILENAME}
   rm ${TASKDEF_TMP_FILENAME}
   echo "TASKDEF_FILENAME: ${TASKDEF_FILENAME}"
   ECS_TASK_FAMILY="$(jq -r '.family' ${TASKDEF_FILENAME})" #extract from json file
   echo "ECS_TASK_FAMILYE: ${ECS_TASK_FAMILY}"
   TASKDEF_IMAGE="$(cat ${TASKDEF_FILENAME} | jq -r '.containerDefinitions[0].image')"
  # ECS_EXISTING_IMAGE="$(aws ecs describe-task-definition ${AWS_PROFILE_ARG} --task-definition ${ECS_TASK_FAMILY})"

  # If the Docker image already deployed is the same as the one specified in the task definition, then skip the update.
  # (This allows Jenkins jobs to be resumed without forcing redeployment of the Docker image.)
  if [[ -z ${ECS_EXISTING_IMAGE} ]] || [[ "${ECS_EXISTING_IMAGE}" != "${TASKDEF_IMAGE}" ]]
  then
      echo "ECS_EXISTING_IMAGE: ${ECS_EXISTING_IMAGE}"
          TASKDEF_STRING="$(cat ${TASKDEF_FILENAME})"

      echo "TASKDEF_STRING: ${TASKDEF_STRING}"
      prepareTaskDefinition "${TASKDEF_STRING}"

      # Write the string back out to the original file
#      echo "${TASKDEF_STRING}" > ${TASKDEF_FILENAME}
      echo "TASKDEF_FILENAME after preperation: ${TASKDEF_FILENAME}"

          # Create new task definition
          aws ecs register-task-definition ${AWS_PROFILE_ARG} --cli-input-json file://${TASKDEF_FILENAME} | jq '.taskDefinition.taskDefinitionArn'
          if [ $? -ne 0 ] ;  then
                echo "An error occurred while trying to create new task definition"
                exit 1
          fi

          # Retrieves the latest revision number.
          # This is not necessary for calling update-service because it will use the latest active revision if none is specified.
          # However, this will allow us to log the new revision number.
          ECS_TASK_REVISION="$(aws ecs describe-task-definition ${AWS_PROFILE_ARG} --task-definition ${ECS_TASK_FAMILY} | jq .taskDefinition.revision)"
      echo "ECS_TASK_REVISION: ${ECS_TASK_REVISION}"

      # Check to see if log group already exists. If it does not, then create it.
      # Add support for multiple containers in single task definision
      updateCloudWatchLogs

          # Retrieves the original task count of the running service (will be restored later)
          ECS_ORIGINAL_TASK_COUNT="$(aws ecs describe-services ${AWS_PROFILE_ARG} --cluster ${ECS_CLUSTER_NAME} --services ${ECS_SERVICE_NAME} | jq '.service
s[0].desiredCount')"
          echo "ECS_ORIGINAL_TASK_COUNT: ${ECS_ORIGINAL_TASK_COUNT}"
          ECS_NEW_TASK_COUNT="${ECS_ORIGINAL_TASK_COUNT}"
          echo "ECS_NEW_TASK_COUNT: ${ECS_NEW_TASK_COUNT}"

          # Retrieves number of registered container instances to make sure there are enough for zero downtime deployment
          ECS_CONTAINER_INSTANCES="$(aws ecs describe-clusters ${AWS_PROFILE_ARG} --cluster ${ECS_CLUSTER_NAME} | jq '.clusters[0].registeredContainerInstanc
esCount')"
          echo "ECS_CONTAINER_INSTANCES: ${ECS_CONTAINER_INSTANCES}"

          # Check to see if a service by this name already exists in the new cluster
      SERVICE_COUNT="$(aws ecs describe-services ${AWS_PROFILE_ARG} --cluster ${ECS_CLUSTER_NAME} --service ${ECS_SERVICE_NAME} | \
                       jq 'del(.services[] | select(.status == "INACTIVE")) | .services | length')"
      echo "INFO: Checking existence of service ${ECS_SERVICE_NAME} in cluster ${ECS_CLUSTER_NAME}: ${SERVICE_COUNT}"

      if [ ${SERVICE_COUNT} == 0 ]; then
                #check if the service use task networking
                TASK_DEF_MODE=`aws ecs describe-task-definition ${AWS_PROFILE_ARG} --task-definition ${ECS_TASK_FAMILY} |jq -r '.taskDefinition.networkMode'`
        if [ "$TASK_DEF_MODE" = "awsvpc" ] ; then
                echo "This script currently doesn't support service creation with task networking. Create the service manually."
            exit 1
        fi
                # Since the service does not exist, create it.
                echo "Attempting to create ECS service ${ECS_SERVICE_NAME} with task definition ${ECS_TASK_FAMILY}:${ECS_TASK_REVISION} on cluster ${ECS_CLUS
TER_NAME}."
        if [ -z "$NEW_SERVICE_LB" ] ; then
          echo "No ELB configured for this service, creating service without ELB"
          aws ecs create-service ${AWS_PROFILE_ARG} --cluster ${ECS_CLUSTER_NAME} --service-name ${ECS_SERVICE_NAME} --task-definition ${ECS_TASK_FAMILY}:${E
CS_TASK_REVISION} \
                                        --desired-count 2 \
                                        --deployment-configuration maximumPercent=200,minimumHealthyPercent=50 | jq '.service.deployments'
        else
          echo "creating ECS service ${ECS_SERVICE_NAME} with ELB ${NEW_SERVICE_LB}."
          aws ecs create-service ${AWS_PROFILE_ARG} --cluster ${ECS_CLUSTER_NAME} --service-name ${ECS_SERVICE_NAME} --task-definition ${ECS_TASK_FAMILY}:${E
CS_TASK_REVISION} \
                                        --desired-count 2 \
                                        --deployment-configuration maximumPercent=200,minimumHealthyPercent=50 \
                                        --load-balancers "${NEW_SERVICE_LB}" | jq '.service.deployments'
                fi
      fi

          echo "Updating service ${ECS_SERVICE_NAME} to use ${ECS_NEW_TASK_COUNT} instances of new task definition."
      aws ecs update-service ${AWS_PROFILE_ARG} --cluster ${ECS_CLUSTER_NAME} --service ${ECS_SERVICE_NAME} \
              --task-definition ${ECS_TASK_FAMILY}:${ECS_TASK_REVISION} --desired-count ${ECS_NEW_TASK_COUNT} \
              --deployment-configuration maximumPercent=200,minimumHealthyPercent=50 | jq '.service.deployments'
      if [ $? -ne 0 ] ; then
          echo "An error occur in aws ecs update-service command, aborting . . ."
          exit 1
      fi

          #validate service was update with latest TD revision
          CURRENT_SERVICE_REVISION=`aws ecs describe-services ${AWS_PROFILE_ARG} --cluster ${ECS_CLUSTER_NAME} --services ${ECS_SERVICE_NAME} |jq '.services[
].taskDefinition'|grep -ow ${ECS_TASK_REVISION}`
        #  if [ "$CURRENT_SERVICE_REVISION" != "$ECS_TASK_REVISION" ] ; then
        #        echo "An error occur in aws ecs update-service command, aborting . . ."
        #        exit 1
        #  fi
          waitForStableService
          echo "${ECS_NEW_TASK_COUNT} tasks of ${ECS_TASK_FAMILY}:${ECS_TASK_REVISION} should be running for ${ECS_SERVICE_NAME} service."
          echo "ECS service update complete."

  else
    echo "The image referenced by the provided task definition (${TASKDEF_IMAGE}) is already deployed to the target environment. Skipping update."
  fi

  # perform temp file cleanup
  rm ${TASKDEF_FILENAME}

else
  #Send error message to stderr
  >&2 echo "Arguments missing. Expected: <task-definition-template> <docker-tag> <ecs-cluster-name> <ecs-service-name>"
  exit 0
fi
