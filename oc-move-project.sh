#!/bin/bash
#author: Olavo Borges
set -e

# Function to display usage
usage() {
    echo "Usage: $0 -p <project_name> -s <source_cluster_api_url> -d <destination_cluster_api_url>"
    echo ""
    echo "Parameters:"
    echo "  -p, --project        Name of the OpenShift project to migrate"
    echo "  -s, --source         API URL of the source OpenShift cluster"
    echo "  -d, --destination    API URL of the destination OpenShift cluster"
    echo ""
    exit 1
}

# Parse input arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -p|--project) PROJECT_NAME="$2"; shift ;;
        -s|--source) SOURCE_CLUSTER="$2"; shift ;;
        -d|--destination) DEST_CLUSTER="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; usage ;;
    esac
    shift
done

# Check if all parameters are provided
if [ -z "$PROJECT_NAME" ] || [ -z "$SOURCE_CLUSTER" ] || [ -z "$DEST_CLUSTER" ]; then
    echo "Error: Missing required parameters."
    usage
fi

# Temporary directory to store exported resources
TEMP_DIR=$(mktemp -d)

echo "=== Migrating project '$PROJECT_NAME' from '$SOURCE_CLUSTER' to '$DEST_CLUSTER' ==="

# Function to login to a cluster
login_cluster() {
    local cluster_url=$1
    local token=$2
    echo "Logging into cluster: $cluster_url"
    oc login "$cluster_url" --token="$token" --insecure-skip-tls-verify=true || {
        echo "Failed to login to cluster: $cluster_url"
        exit 1
    }
}

# Ensure SOURCE_TOKEN and DEST_TOKEN are set
if [ -z "$SOURCE_TOKEN" ] || [ -z "$DEST_TOKEN" ]; then
    echo "Error: SOURCE_TOKEN and DEST_TOKEN environment variables must be set with appropriate OpenShift tokens."
    exit 1
fi

# Login to Source Cluster
echo "=== Logging into Source Cluster ==="
login_cluster "$SOURCE_CLUSTER" "$SOURCE_TOKEN"

# Set project
oc project "$PROJECT_NAME" || {
    echo "Project '$PROJECT_NAME' does not exist in source cluster."
    exit 1
}

# Export all resources except Secrets and ConfigMaps initially
echo "=== Exporting resources from Source Cluster ==="
oc get all,role,rolebinding,serviceaccount -o json > "$TEMP_DIR/resources.json"

# Export ConfigMaps and Secrets separately to handle them securely
echo "=== Exporting ConfigMaps and Secrets ==="
oc get configmaps,secrets -o json > "$TEMP_DIR/configs_secrets.json"

# Save ImageStreams
echo "=== Exporting ImageStreams ==="
oc get imagestreams -o json > "$TEMP_DIR/imagestreams.json"

# Save BuildConfigs
echo "=== Exporting BuildConfigs ==="
oc get bc -o json > "$TEMP_DIR/buildconfigs.json"

# Save DeploymentConfigs if any
echo "=== Exporting DeploymentConfigs ==="
oc get dc -o json > "$TEMP_DIR/deploymentconfigs.json"

# Export Routes
echo "=== Exporting Routes ==="
oc get routes -o json > "$TEMP_DIR/routes.json"

# Login to Destination Cluster
echo "=== Logging into Destination Cluster ==="
login_cluster "$DEST_CLUSTER" "$DEST_TOKEN"

# Create project in Destination Cluster
echo "=== Creating project '$PROJECT_NAME' in Destination Cluster ==="
oc new-project "$PROJECT_NAME" || {
    echo "Project '$PROJECT_NAME' already exists in destination cluster."
}

# Switch to Destination Project
oc project "$PROJECT_NAME"

# Apply ImageStreams first
echo "=== Applying ImageStreams ==="
oc apply -f "$TEMP_DIR/imagestreams.json" --ignore-unknown=true

# Apply BuildConfigs
echo "=== Applying BuildConfigs ==="
oc apply -f "$TEMP_DIR/buildconfigs.json" --ignore-unknown=true

# Apply DeploymentConfigs
echo "=== Applying DeploymentConfigs ==="
oc apply -f "$TEMP_DIR/deploymentconfigs.json" --ignore-unknown=true

# Apply other resources
echo "=== Applying other resources ==="
oc apply -f "$TEMP_DIR/resources.json" --ignore-unknown=true

# Apply ConfigMaps and Secrets
echo "=== Applying ConfigMaps and Secrets ==="
oc apply -f "$TEMP_DIR/configs_secrets.json" --ignore-unknown=true

# Handle Routes
echo "=== Applying Routes ==="

# Remove the 'host' field from Routes to let OpenShift assign a new host
jq 'del(.items[].spec.host)' "$TEMP_DIR/routes.json" > "$TEMP_DIR/routes_modified.json"

oc apply -f "$TEMP_DIR/routes_modified.json" --ignore-unknown=true

# Wait for Routes to be assigned a host
echo "=== Waiting for Routes to be assigned a host ==="
sleep 10  # Adjust sleep time as necessary

# Retrieve and output the new Route URLs
echo "=== Retrieving new Route URLs ==="
oc get routes -o json | jq -r '.items[] | select(.spec.to.name != "kubernetes") | "\(.metadata.name): https://\(.status.ingress[].host)"' > "$TEMP_DIR/new_routes.txt"

echo "=== New Routes URLs ==="
cat "$TEMP_DIR/new_routes.txt"

# Clean up temporary directory
echo "=== Cleaning up temporary files ==="
rm -rf "$TEMP_DIR"

echo "=== Migration completed successfully ==="
