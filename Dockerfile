# VERSION 1.8.1
# AUTHOR: Matthieu "Puckel_" Roisil
# DESCRIPTION: Basic Airflow container
# BUILD: docker build --rm -t puckel/docker-airflow .
# SOURCE: https://github.com/puckel/docker-airflow

# Compile and include the AWS credential helper
FROM golang:1.8.3 as aws_ecr_credential_helper
WORKDIR /go/src/github.com/awslabs/
RUN git clone https://github.com/awslabs/amazon-ecr-credential-helper.git
WORKDIR /go/src/github.com/awslabs/amazon-ecr-credential-helper
RUN make

FROM debian:jessie
MAINTAINER Puckel_

# Never prompts the user for choices on installation/configuration of packages
ENV DEBIAN_FRONTEND noninteractive
ENV TERM linux

# Airflow
ARG AIRFLOW_VERSION=1.8.1
ARG AIRFLOW_HOME=/usr/local/airflow

# Define en_US.
ENV LANGUAGE en_US.UTF-8
ENV LANG en_US.UTF-8
ENV LC_ALL en_US.UTF-8
ENV LC_CTYPE en_US.UTF-8
ENV LC_MESSAGES en_US.UTF-8
ENV LC_ALL en_US.UTF-8

RUN set -ex \
    && buildDeps=' \
        python-dev \
        libkrb5-dev \
        libsasl2-dev \
        libssl-dev \
        libffi-dev \
        build-essential \
        libblas-dev \
        liblapack-dev \
        libpq-dev \
        git \
    ' \
    && apt-get update -yqq \
    && apt-get install -yqq --no-install-recommends \
        $buildDeps \
        python-pip \
        python-requests \
        apt-utils \
        curl \
        netcat \
        locales \
    && sed -i 's/^# en_US.UTF-8 UTF-8$/en_US.UTF-8 UTF-8/g' /etc/locale.gen \
    && locale-gen \
    && update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 \
    && useradd -ms /bin/bash -d ${AIRFLOW_HOME} airflow \
    && python -m pip install -U pip \
    && pip install -U setuptools \
    && pip install Cython \
    && pip install pytz \
    && pip install pyOpenSSL \
    && pip install ndg-httpsclient \
    && pip install pyasn1 \
    && pip install apache-airflow[crypto,celery,postgres,hive,hdfs,jdbc]==$AIRFLOW_VERSION \
    && pip install celery[redis]==3.1.17

RUN curl -fsSL https://get.docker.com/ | sh
RUN pip install docker-py
RUN pip install awscli

RUN apt-get remove --purge -yqq $buildDeps \
    && apt-get clean \
    && rm -rf \
        /var/lib/apt/lists/* \
        /tmp/* \
        /var/tmp/* \
        /usr/share/man \
        /usr/share/doc \
        /usr/share/doc-base

COPY script/entrypoint.sh /entrypoint.sh
COPY config/airflow.cfg ${AIRFLOW_HOME}/airflow.cfg

# copy the built docker credentials module to this container
COPY --from=aws_ecr_credential_helper \
    /go/src/github.com/awslabs/amazon-ecr-credential-helper/bin/local/docker-credential-ecr-login \
    /usr/local/bin
COPY --from=aws_ecr_credential_helper \
	/go/src/github.com/awslabs/amazon-ecr-credential-helper/bin/local/docker-credential-ecr-login \
	/usr/bin
COPY --from=aws_ecr_credential_helper \
	/go/src/github.com/awslabs/amazon-ecr-credential-helper/bin/local/docker-credential-ecr-login \
	/usr/sbin
COPY --from=aws_ecr_credential_helper \
	/go/src/github.com/awslabs/amazon-ecr-credential-helper/bin/local/docker-credential-ecr-login \
	/bin

RUN adduser airflow docker
WORKDIR ${AIRFLOW_HOME}/.docker
RUN echo '{\n    "credStore": "ecr-login"\n}' > config.json
RUN chown -R airflow: ${AIRFLOW_HOME}

EXPOSE 8080 5555 8793

USER airflow
WORKDIR ${AIRFLOW_HOME}
ENTRYPOINT ["/entrypoint.sh"]


