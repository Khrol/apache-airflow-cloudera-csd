#!/bin/bash


# Creating the AIRFLOW_HOME directory
if [ ! -d ${airflow_home} ]; then
    mkdir -p ${airflow_home}
    chown -R airflow:airflow ${airflow_home}
fi

# Creating the Airflow log directory
if [ ! -d ${base_log_folder} ]; then
    mkdir -p ${base_log_folder}
    chown -R airflow:airflow ${base_log_folder}
fi

# Creating dags folder
if [ ! -d ${dags_folder} ]; then
    mkdir -p ${dags_folder}
    chown -R airflow:airflow ${dags_folder}
    chmod 775 ${dags_folder}
fi

# Initializing the Airflow database if not existed
if [ ! -f ${airflow_home}/airflow.cfg ]; then
    sudo -Eu airflow bash -c 'export PATH=${AIRFLOW_DIR}/usr/bin:$PATH;
    exec airflow initdb'
fi

# Building connection string
if [ "$dbType" == "mysql" ]; then
    sql_alchemy_conn="mysql://${dbUser}:${dbPass}@${dbHost}:${dbPort}/${dbName}"
elif [ "$dbType" == "postgresql" ]; then
    sql_alchemy_conn="postgresql+psycopg2://${dbUser}:${dbPass}@${dbHost}:${dbPort}/${dbName}"
fi


# Creating RabbitMQ User

export HOME=`eval echo ~$USER`

${RABBITMQ_DIR}/usr/lib/rabbitmq/bin/rabbitmqctl status
exit_code="$?"
echo "rabbitmqctl status exit code is $exit_code"

if [ $exit_code == 0 ]; then
    ${RABBITMQ_DIR}/usr/lib/rabbitmq/bin/rabbitmqctl add_user ${RABBITMQ_USER} ${RABBITMQ_PASS}
    ${RABBITMQ_DIR}/usr/lib/rabbitmq/bin/rabbitmqctl set_permissions ${RABBITMQ_USER} ".*" ".*" ".*"
else
    counter=0
    while [ $counter -le 4 ] && [ $exit_code == 69 ]
    do
        nohup ${RABBITMQ_DIR}/usr/lib/rabbitmq/bin/rabbitmq-server start &
        exit_code="$?"
        echo "rabbitmq-server exit code is $exit_code"
        counter=$(($counter+1))
        sleep 3
    done

    ${RABBITMQ_DIR}/usr/lib/rabbitmq/bin/rabbitmqctl status
    exit_code_status="$?"
    counter_status=0

    while [ $counter_status -le 4 ] && [ $exit_code_status != 0 ]
    do
        sleep 3
        ${RABBITMQ_DIR}/usr/lib/rabbitmq/bin/rabbitmqctl status
        exit_code_status="$?"
        counter_status=$(($counter_status+1))
    done

    if [ $counter -gt 4 ] && [ $exit_code != 0 ] && [ $counter_status -gt 4 ] && [ $exit_code_status != 0 ]
    then
        echo "Cannot start Rabbitmq server to create users"
        exit 1
    fi


    exit_code_add_user=1
    counter_add_user=0

    while [ $counter_add_user -le 4 ] && [ $exit_code_add_user == 1 ]
    do
        ${RABBITMQ_DIR}/usr/lib/rabbitmq/bin/rabbitmqctl add_user ${RABBITMQ_USER} ${RABBITMQ_PASS}
        exit_code_add_user="$?"
        echo "exit_code for adding user is $exit_code_add_user"
        counter_add_user=$(($counter_add_user+1))
    done

    if [ $counter_add_user -gt 4 ] && [ $exit_code_add_user != 0 ] && [ $exit_code_add_user != 70 ]
    then
        echo "Failed to add user $RABBITMQ_USER"
        exit 1
    fi


    exit_code_set_admin=1
    counter_set_admin=0

    while [ $counter_set_admin -le 4 ] && [ $exit_code_set_admin == 1 ]
    do
        ${RABBITMQ_DIR}/usr/lib/rabbitmq/bin/rabbitmqctl set_user_tags ${RABBITMQ_USER} administrator
        exit_code_set_admin="$?"
        echo "exit code for adding administrator is $exit_code_set_admin"
        counter_set_admin=$(($counter_add_user+1))
    done

    if [ $counter_set_admin -gt 4 ] && [ $exit_code_set_admin != 0 ]
    then
        echo "Failed to add user $RABBITMQ_USER"
        exit 1
    fi


    exit_code_permissions=1
    counter_permissions=0

    while [ $counter_permissions -le 4 ] && [ $exit_code_permissions == 1 ]
    do
        ${RABBITMQ_DIR}/usr/lib/rabbitmq/bin/rabbitmqctl set_permissions ${RABBITMQ_USER} ".*" ".*" ".*"
        exit_code_permissions="$?"
        counter_permissions=$(($counter_permissions+1))
    done

    if [ $counter_permissions -gt 4 ] && [ $exit_code_permissions != 0 ]
    then
        echo "Failed to modify permssions to $RABBITMQ_USER user"
        exit 1
    fi


    exit_code_stop=1
    counter_stop=0

    while [ $counter_stop -le 4 ] && [ $exit_code_stop == 1 ]
    do
        echo "Stopping Rabbitmq instance..."
        sh ../scripts/stop_rabbitmq.sh
        exit_code_stop="$?"
        counter_stop=$(($counter_stop+1))
    done

    if [ $counter_stop -gt 4 ] && [ $exit_code_stop != 0 ]
    then
        echo "Failed to stop Rabbitmq server after user creation"
        exit 1
    fi
        
fi


# Updating airflow.cfg

broker_url="amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@${RABBITMQ_HOST}:${RABBITMQ_PORT}/"
celery_result_backend="db+${sql_alchemy_conn}"

PWCMD='< /dev/urandom tr -dc A-Za-z0-9 | head -c 20;echo'
secret_key=`eval $PWCMD`

function replace {
    sed -i "s#${1}#${2}#g" $3
}

function remove_line {
    sed -i "/${1}/d" $2
}

echo "Updating airflow.cfg..."
auth_backend_flag=false
auth_backend=airflow.contrib.auth.backends.password_auth

# Updating airflow.cfg
while read line; do
    key=$(cut -d "=" -f1 <<< "$line" | xargs)
    value=$(cut -d "=" -f2 <<< "$line")
    if [[ ${!key} ]]; then
        if [[ "$key" != "#" ]]; then
            if [[ "$key" == "authenticate" ]]; then
                replace "$key =${value}" "$key = ${!key}\nauth_backend = airflow.contrib.auth.backends.password_auth" ${airflow_home}/airflow.cfg
            elif [[ "$key" == "auth_backend" ]]; then
                if [[ "$auth_backend_flag" = true ]]; then
                    sed -i "/auth_backend = airflow.contrib.auth.backends.password_auth/d" ${airflow_home}/airflow.cfg
                fi
                auth_backend_flag=true
            else
                replace "$key =${value}" "$key = ${!key}" ${airflow_home}/airflow.cfg
            fi
        fi
    fi
done < ${airflow_home}/airflow.cfg


echo "Creating Airflow user..."
# Creating Airflow User

if [[ ! -z "$AIRFLOW_USER" ]];
then 
    ${AIRFLOW_DIR}/usr/bin/python2.7 ../scripts/mkuser.py $AIRFLOW_USER $AIRFLOW_EMAIL $AIRFLOW_PASS
fi


echo "Updating AIRFLOW_HOME in binaries..."
# Creating the airflow binary
sed -i "1s+.*+export AIRFLOW_HOME=${AIRFLOW_HOME}\n+" ${AIRFLOW_DIR}/bin/airflow.sh

echo "export AIRFLOW_HOME=${AIRFLOW_HOME}" > /usr/bin/airflow-mkuser
echo "export PYTHONPATH=${PYTHONPATH}" >> /usr/bin/airflow-mkuser
echo "export PATH=${AIRFLOW_DIR}/bin:\$PATH" >> /usr/bin/airflow-mkuser
echo "${AIRFLOW_DIR}/bin/mkuser.sh \$@" >> /usr/bin/airflow-mkuser