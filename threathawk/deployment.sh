#!/bin/bash

# Function to check and install packages
check_install_package() {
    if ! dpkg -l "$1" &>/dev/null; then
        echo -e "\e[31m[SCRIPT] Installing $1...\e[0m"
        sudo apt-get update && sudo apt-get install -y "$1"
        if [ $? -ne 0 ]; then
            echo -e "\e[31m[SCRIPT] Error: Failed to install $1\e[0m"
            exit 1
        fi
    fi
}

# Check and install required packages
check_install_package "docker.io"
check_install_package "docker-compose"
check_install_package "python3-pip"

# Create Docker network if it doesn't exist
if ! sudo docker network inspect threat_hawk_network &>/dev/null; then
    echo -e "\e[31m[SCRIPT] Creating Docker network: threat_hawk_network\e[0m"
    sudo docker network create threat_hawk_network
    if [ $? -ne 0 ]; then
        echo -e "\e[31m[SCRIPT] Error: Failed to create Docker network: threat_hawk_network\e[0m"
        exit 1
    fi
else
    echo -e "\e[31m[SCRIPT] Docker network threat_hawk_network already exists. Skipping network creation.\e[0m"
fi

# Define directory to clone repositories into
directory="threathawk"

# Create directory if it doesn't exist
if [ ! -d "$directory" ]; then
    mkdir "$directory"
fi

# Clone repositories into threathawk directory if they don't exist
repos=(
    "threathawkproject/frontend"
    "threathawkproject/enrichment"
    "threathawkproject/encoding"
    "threathawkproject/investigation"
    "threathawkproject/ioc_aggregator"
    "wurstmeister/kafka-docker"
)

for repo in "${repos[@]}"; do
    repo_name=$(basename "$repo")
    if [ ! -d "$directory/$repo_name" ]; then
        echo -e "\e[31m[SCRIPT] Cloning $repo...\e[0m"
        git clone "https://github.com/$repo.git" "$directory/$repo_name"
        if [ $? -ne 0 ]; then
            echo -e "\e[31m[SCRIPT] Error: Failed to clone $repo\e[0m"
            exit 1
        fi
    else
        echo -e "\e[31m[SCRIPT] Directory $directory/$repo_name already exists. Skipping clone.\e[0m"
    fi
done

# Go into each folder, install requirements if available, and run docker-compose up (except for wurstmeister/threathawk)
cd "$directory" || exit

for repo in "${repos[@]}"; do
    repo_name=$(basename "$repo")
    cd "$repo_name" || continue
    
    # Create docker-compose.yml for threathawkproject/ioc_aggregator
    if [ "$repo" == "threathawkproject/ioc_aggregator" ]; then
        echo -e "\e[31m[SCRIPT] Creating docker-compose.yml for $repo...\e[0m"
        cat <<EOF > docker-compose.yml
version: '3.7'
services:
  postgres:
    image: postgres:latest
    restart: always
    environment:
      - POSTGRES_PASSWORD=1234
      - POSTGRES_DB=ioc_feeds
    ports:
      - '5432:5432'
    networks:
      - threat_hawk_network
    volumes:
      - ./postgres-data:/var/lib/postgresql/data

  zookeeper:
    image: wurstmeister/zookeeper
    ports:
      - "2181:2181"
    restart: unless-stopped
    depends_on:
      - postgres  # Zookeeper starts after Postgres
    networks:
      - threat_hawk_network
      
  kafka:
    build: ../kafka-docker
    ports:
      - "9092:9092"
    depends_on:
      - postgres  # Kafka waits for healthy Postgres
      - zookeeper  # Kafka waits for healthy Zookeeper
    environment:
      DOCKER_API_VERSION: 1.22
      KAFKA_ADVERTISED_HOST_NAME: 127.0.0.1
      KAFKA_ZOOKEEPER_CONNECT: zookeeper:2181
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    restart: unless-stopped
    networks:
      - threat_hawk_network

networks:
  threat_hawk_network:
    external: true
EOF
    fi

    # Install requirements if available
    if [ -f "requirements.txt" ]; then
        echo -e "\e[31m[SCRIPT] Installing requirements for $repo...\e[0m"
        pip install -r requirements.txt
        if [ $? -ne 0 ]; then
            echo -e "\e[31m[SCRIPT] Error: Failed to install requirements for $repo\e[0m"
            exit 1
        fi
    else
        echo -e "\e[31m[SCRIPT] No requirements.txt file found for $repo. Skipping installation.\e[0m"
    fi
    
    # Skip docker-compose up if repo is wurstmeister/kafka-docker
    if [ "$repo" != "wurstmeister/kafka-docker" ]; then
        echo -e "\e[31m[SCRIPT] Running docker-compose up for $repo...\e[0m"
        sudo docker-compose up -d
        if [ $? -ne 0 ]; then
            echo -e "\e[31m[SCRIPT] Error: Failed to run docker-compose up for $repo\e[0m"
            exit 1
        fi
    else
        echo -e "\e[31m[SCRIPT] Skipping docker-compose up for wurstmeister/threathawk as ioc-aggregator builds kafka-docker.\e[0m"
    fi

    # Change directory back to the main folder
    cd ..
done
