# Versions
CASSANDRA_VERSION_DEFAULT="3.9"

ELASTICSEARCH_VERSION_DEFAULT="5.6.9"

MYSQL_VERSION_DEFAULT="8.0.30"

PGSQL_VERSION_DEFAULT=latest

COCKROACHDB_VERSION_DEFAULT="latest"

MSSQL_VERSION_DEFAULT="2022-CU12-ubuntu-22.04"

LDAP_VERSION_DEFAULT="1.5.0"

REDIS_VERSION_DEFAULT="7.2.1"

RMQ_VERSION_DEFAULT="3.11-alpine"

MINIO_VERSION_DEFAULT="RELEASE.2021-04-22T15-44-28Z.hotfix.56647434e"
MINIO_MC_VERSION_DEFAULT="RELEASE.2022-01-29T01-03-27Z"

# Allow to override
CASSANDRA_VERSION=${CASSANDRA_VERSION:-$CASSANDRA_VERSION_DEFAULT}

ELASTICSEARCH_VERSION=${ELASTICSEARCH_VERSION:-$ELASTICSEARCH_VERSION_DEFAULT}

MYSQL_VERSION=${MYSQL_VERSION:-$MYSQL_VERSION_DEFAULT}

PGSQL_VERSION=${PGSQL_VERSION:-$PGSQL_VERSION_DEFAULT}

COCKROACHDB_VERSION=${COCKROACHDB_VERSION:-$COCKROACHDB_VERSION_DEFAULT}

MSSQL_VERSION=${MSSQL_VERSION:-$MSSQL_VERSION_DEFAULT}

LDAP_VERSION=${LDAP_VERSION:-$LDAP_VERSION_DEFAULT}

REDIS_VERSION=${REDIS_VERSION:-$REDIS_VERSION_DEFAULT}

RMQ_VERSION=${RMQ_VERSION:-$RMQ_VERSION_DEFAULT}

MINIO_VERSION=${MINIO_VERSION:-$MINIO_VERSION_DEFAULT}
MINIO_MC_VERSION=${MINIO_MC_VERSION:-$MINIO_MC_VERSION_DEFAULT}
