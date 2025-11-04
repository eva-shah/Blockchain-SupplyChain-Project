#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/env_exports.sh"
TN="$HOME/fabric-samples/test-network"
cd "$TN"

# Org1
export CORE_PEER_LOCALMSPID=MakerMSP
export CORE_PEER_ADDRESS=localhost:7051
export CORE_PEER_MSPCONFIGPATH=$TN/organizations/peerOrganizations/maker.example.com/users/Admin@maker.example.com/msp
export CORE_PEER_TLS_ROOTCERT_FILE=$TN/organizations/peerOrganizations/maker.example.com/peers/peer0.maker.example.com/tls/ca.crt

echo "== CreateProduct on main-supply =="
peer chaincode invoke -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
  --tls --cafile $ORDERER_CA \
  -C main-supply -n trackchain -c '{"Args":["CreateProduct","P200","SKU-ALPHA","Smart Sensor Module"]}'

echo "== CreateShipment on manu-dist =="
peer chaincode invoke -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
  --tls --cafile $ORDERER_CA \
  -C manu-dist -n trackchain -c '{"Args":["CreateShipment","S200","P200","WholesalerMSP"]}'

# Org2
export CORE_PEER_LOCALMSPID=WholesalerMSP
export CORE_PEER_ADDRESS=localhost:9051
export CORE_PEER_MSPCONFIGPATH=$TN/organizations/peerOrganizations/wholesaler.example.com/users/Admin@wholesaler.example.com/msp
export CORE_PEER_TLS_ROOTCERT_FILE=$TN/organizations/peerOrganizations/wholesaler.example.com/peers/peer0.wholesaler.example.com/tls/ca.crt

echo "== ReceiveShipment on manu-dist (Org2) =="
peer chaincode invoke -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
  --tls --cafile $ORDERER_CA \
  -C manu-dist -n trackchain -c '{"Args":["ReceiveShipment","S200"]}'

echo "== GetProduct on main-supply =="
peer chaincode query -C main-supply -n trackchain -c '{"Args":["GetProduct","P200"]}'

echo "== GetProductHistory on main-supply =="
peer chaincode query -C main-supply -n trackchain -c '{"Args":["GetProductHistory","P200"]}'

# Unauthorized: Org3 tries on manu-dist
export CORE_PEER_LOCALMSPID=RetailerMSP
export CORE_PEER_ADDRESS=localhost:11051
export CORE_PEER_MSPCONFIGPATH=$TN/organizations/peerOrganizations/retailer.example.com/users/Admin@retailer.example.com/msp
export CORE_PEER_TLS_ROOTCERT_FILE=$TN/organizations/peerOrganizations/retailer.example.com/peers/peer0.retailer.example.com/tls/ca.crt

echo "== Unauthorized ReceiveShipment as Org3 (should fail) =="
set +e
peer chaincode invoke -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
  --tls --cafile $ORDERER_CA \
  -C manu-dist -n trackchain -c '{"Args":["ReceiveShipment","S200"]}'
echo "EXPECTED FAILURE ABOVE (screenshot this error)"
set -e
