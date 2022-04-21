#!/bin/bash
export AWS_SHARED_CREDENTIALS_FILE=/etc/backup/credentials
CURRENT_DATE=$(date -u +%Y%m%d%H%M%S)

usage() { 
    echo "Usage: $0 -f <rocketchat folder> -d <s3 destination> [-r <retain count>]";
    exit 1;
}

while getopts ":f:d:r:" o; do
    case "${o}" in
        f)
            ROCKETCHAT_FOLDER=${OPTARG}
            ;;
        d)
            S3_DST=${OPTARG}
            ;;
        r)
            RETAIN_CNT=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [[ -z "${RETAIN_CNT}" ]]; then
    RETAIN_CNT=0
fi

if [ -z "${ROCKETCHAT_FOLDER}" ] || [ -z "${S3_DST}" ]; then
    usage
fi

#file lock
LOCKFILE="/var/run/backup_${NAME}.lock"
TIMEOUT=1
touch $LOCKFILE
exec {FD}<>$LOCKFILE

if ! flock -x -w $TIMEOUT $FD; then
    echo "fail to lock"
    exit 1;
fi

send_notification()
{   
    if [ -f "/usr/local/bin/apprise" ] && [ -f "/etc/backup/apprise_config" ]; then
            /usr/local/bin/apprise  -t "${1}" -b "${2}" --config=/etc/backup/apprise_config
    fi
    exit 1
}

#docker-compose
cd $ROCKETCHAT_FOLDER
docker-compose ps
SEARCH_DOCKER_COMPOSE=$?

#Archieve to S3. Notification telegram
if [[ $SEARCH_DOCKER_COMPOSE -gt 0 ]]; then
        send_notification "Mongo backup docker-compose not found with exit code ${SEARCH_DOCKER_COMPOSE}" 
fi

DST_FILE_NAME="rocketchat-${CURRENT_DATE}"

DOCKER_COMPOSE=$(which docker-compose)
cd $ROCKETCHAT_FOLDER && \
$DOCKER_COMPOSE exec -T mongo sh -c 'mongodump --db rocketchat --archive' | aws s3 cp - ${S3_DST}/${DST_FILE_NAME}

#Upload to S3. Notification telegram
AWS_RESULT=$?
if [[ $AWS_RESULT  -gt 0 ]];  then
     send_notification "Failed to upload mongo archive" "Could't to upload mongo backup to ${S3_DST} with exit code ${AWS_RESULT}"
fi

if [[ $RETAIN_CNT -gt 0 ]]; then
    REMOTE_FILES=$(aws s3 ls ${S3_DST} | sort | awk '{print $4}') 
    echo "$REMOTE_FILES" | grep -v "`echo \"$REMOTE_FILES\" | tail -n ${RETAIN_CNT}`" | \
    while read file; do \
        aws s3 rm "${S3_DST}/${file}"; \
    done
fi
