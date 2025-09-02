# Install Clickhouse Operator

## Using Kubectl

```
kubectl apply -f https://raw.githubusercontent.com/Altinity/clickhouse-operator/master/deploy/operator/clickhouse-operator-install-bundle.yaml
```

## Using helm

```
helm repo add clickhouse-operator https://docs.altinity.com/clickhouse-operator/
helm install clickhouse-operator clickhouse-operator/altinity-clickhouse-operator
```

#### Upgrade

```
helm repo upgrade clickhouse-operator
helm upgrade clickhouse-operator clickhouse-operator/altinity-clickhouse-operator
```
