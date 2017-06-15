#!/usr/bin/env bash
DOCKER_SOCKET=/var/run/docker.sock
DOCKER_GROUP=docker
AIRFLOW_USER=airflow

# In order run DooD (Docker outside of Docker) we need to make sure the
# container's docker group id matches the host's group id. If it doens't match,
# update the group id and then restart the script. (also remove sudoer privs)
if [ ! -S ${DOCKER_SOCKET} ]; then
    echo 'Docker socket not found!'
else
    DOCKER_GID=$(stat -c '%g' $DOCKER_SOCKET)
    if $(id -G $AIRFLOW_USER | grep -qw $DOCKER_GID); then
        echo "User $AIRFLOW_USER in the correct host docker groupid $DOCKER_GID"
    else
        echo "User $AIRFLOW_USER not in the correct group $DOCKER_GID"
        echo "Updating docker group to host docker group $DOCKER_GID"
        sudo groupmod -g ${DOCKER_GID} ${DOCKER_GROUP}
        # it doens't protect from docker but it's a little more secure
        sudo sed -i "/$AIRFLOW_USER/d" /etc/sudoers
        echo "Restarting script"
        exec sg $DOCKER_GROUP "$0 $*"
    fi
fi

AIRFLOW_HOME="/usr/local/airflow"
CMD="airflow"
TRY_LOOP="20"

: ${REDIS_HOST:="redis"}
: ${REDIS_PORT:="6379"}
: ${REDIS_PASSWORD:=""}

: ${POSTGRES_HOST:="postgres"}
: ${POSTGRES_PORT:="5432"}
: ${POSTGRES_USER:="airflow"}
: ${POSTGRES_PASSWORD:="airflow"}
: ${POSTGRES_DB:="airflow"}

: ${FERNET_KEY:=$(python -c "from cryptography.fernet import Fernet; FERNET_KEY = Fernet.generate_key().decode(); print(FERNET_KEY)")}

# Load DAGs exemples (default: Yes)
if [ "$LOAD_EX" = "n" ]; then
    sed -i "s/load_examples = True/load_examples = False/" "$AIRFLOW_HOME"/airflow.cfg
fi

# Install custome python package if requirements.txt is present
if [ -e "/requirements.txt" ]; then
    $(which pip) install --user -r /requirements.txt
fi

# Update airflow config - Fernet key
sed -i "s|\$FERNET_KEY|$FERNET_KEY|" "$AIRFLOW_HOME"/airflow.cfg

if [ -n "$REDIS_PASSWORD" ]; then
    REDIS_PREFIX=:${REDIS_PASSWORD}@
else
    REDIS_PREFIX=
fi

# Wait for Postresql
if [ "$1" = "webserver" ] || [ "$1" = "worker" ] || [ "$1" = "scheduler" ] ; then
  i=0
  while ! nc -z $POSTGRES_HOST $POSTGRES_PORT >/dev/null 2>&1 < /dev/null; do
    i=$((i+1))
    if [ "$1" = "webserver" ]; then
      echo "$(date) - waiting for ${POSTGRES_HOST}:${POSTGRES_PORT}... $i/$TRY_LOOP"
      if [ $i -ge $TRY_LOOP ]; then
        echo "$(date) - ${POSTGRES_HOST}:${POSTGRES_PORT} still not reachable, giving up"
        exit 1
      fi
    fi
    sleep 10
  done
fi

# Update configuration depending the type of Executor
if [ "$EXECUTOR" = "Celery" ]
then
  # Wait for Redis
  if [ "$1" = "webserver" ] || [ "$1" = "worker" ] || [ "$1" = "scheduler" ] || [ "$1" = "flower" ] ; then
    j=0
    while ! nc -z $REDIS_HOST $REDIS_PORT >/dev/null 2>&1 < /dev/null; do
      j=$((j+1))
      if [ $j -ge $TRY_LOOP ]; then
        echo "$(date) - $REDIS_HOST still not reachable, giving up"
        exit 1
      fi
      echo "$(date) - waiting for Redis... $j/$TRY_LOOP"
      sleep 5
    done
  fi
  sed -i "s#celery_result_backend = db+postgresql://airflow:airflow@postgres/airflow#celery_result_backend = db+postgresql://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB#" "$AIRFLOW_HOME"/airflow.cfg
  sed -i "s#sql_alchemy_conn = postgresql+psycopg2://airflow:airflow@postgres/airflow#sql_alchemy_conn = postgresql+psycopg2://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB#" "$AIRFLOW_HOME"/airflow.cfg
  sed -i "s#broker_url = redis://redis:6379/1#broker_url = redis://$REDIS_PREFIX$REDIS_HOST:$REDIS_PORT/1#" "$AIRFLOW_HOME"/airflow.cfg
  if [ "$1" = "webserver" ]; then
    echo "Initialize database..."
    $CMD initdb
    exec $CMD webserver
  else
    sleep 10
    exec $CMD "$@"
  fi
elif [ "$EXECUTOR" = "Local" ]
then
  sed -i "s/executor = CeleryExecutor/executor = LocalExecutor/" "$AIRFLOW_HOME"/airflow.cfg
  sed -i "s#sql_alchemy_conn = postgresql+psycopg2://airflow:airflow@postgres/airflow#sql_alchemy_conn = postgresql+psycopg2://$POSTGRES_USER:$POSTGRES_PASSWORD@$POSTGRES_HOST:$POSTGRES_PORT/$POSTGRES_DB#" "$AIRFLOW_HOME"/airflow.cfg
  sed -i "s#broker_url = redis://redis:6379/1#broker_url = redis://$REDIS_PREFIX$REDIS_HOST:$REDIS_PORT/1#" "$AIRFLOW_HOME"/airflow.cfg
  echo "Initialize database..."
  $CMD initdb
  exec $CMD webserver &
  exec $CMD scheduler
# By default we use SequentialExecutor
else
  if [ "$1" = "version" ]; then
    exec $CMD version
    exit
  fi
  sed -i "s/executor = CeleryExecutor/executor = SequentialExecutor/" "$AIRFLOW_HOME"/airflow.cfg
  sed -i "s#sql_alchemy_conn = postgresql+psycopg2://airflow:airflow@postgres/airflow#sql_alchemy_conn = sqlite:////usr/local/airflow/airflow.db#" "$AIRFLOW_HOME"/airflow.cfg
  echo "Initialize database..."
  $CMD initdb
  exec $CMD webserver
fi
