#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/env_exports.sh"
TN="$HOME/fabric-samples/test-network"
export FABRIC_CFG_PATH="$TN"
cd "$TN"

peer lifecycle chaincode package trackchain.tgz \
  --path "$HOME/Desktop/TrackChain/chaincode/trackchain-js" \
  --lang node --label trackchain_1

# Org1 install
export CORE_PEER_LOCALMSPID=MakerMSP
export CORE_PEER_ADDRESS=localhost:7051
export CORE_PEER_MSPCONFIGPATH=$TN/organizations/peerOrganizations/maker.example.com/users/Admin@maker.example.com/msp
export CORE_PEER_TLS_ROOTCERT_FILE=$TN/organizations/peerOrganizations/maker.example.com/peers/peer0.maker.example.com/tls/ca.crt
peer lifecycle chaincode install trackchain.tgz
PKG_ID=$(peer lifecycle chaincode queryinstalled | sed -n 's/Package ID: \(trackchain_1:[^,]*\),.*/\1/p')

# Org2 install
export CORE_PEER_LOCALMSPID=WholesalerMSP
export CORE_PEER_ADDRESS=localhost:9051
export CORE_PEER_MSPCONFIGPATH=$TN/organizations/peerOrganizations/wholesaler.example.com/users/Admin@wholesaler.example.com/msp
export CORE_PEER_TLS_ROOTCERT_FILE=$TN/organizations/peerOrganizations/wholesaler.example.com/peers/peer0.wholesaler.example.com/tls/ca.crt
peer lifecycle chaincode install trackchain.tgz

# Approvals
export CORE_PEER_LOCALMSPID=MakerMSP
export CORE_PEER_ADDRESS=localhost:7051
export CORE_PEER_MSPCONFIGPATH=$TN/organizations/peerOrganizations/maker.example.com/users/Admin@maker.example.com/msp
export CORE_PEER_TLS_ROOTCERT_FILE=$TN/organizations/peerOrganizations/maker.example.com/peers/peer0.maker.example.com/tls/ca.crt
peer lifecycle chaincode approveformyorg -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --channelID manu-dist --name trackchain --version 1.0 \
  --package-id $PKG_ID --sequence 1 --tls --cafile $ORDERER_CA

export CORE_PEER_LOCALMSPID=WholesalerMSP
export CORE_PEER_ADDRESS=localhost:9051
export CORE_PEER_MSPCONFIGPATH=$TN/organizations/peerOrganizations/wholesaler.example.com/users/Admin@wholesaler.example.com/msp
export CORE_PEER_TLS_ROOTCERT_FILE=$TN/organizations/peerOrganizations/wholesaler.example.com/peers/peer0.wholesaler.example.com/tls/ca.crt
peer lifecycle chaincode approveformyorg -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --channelID manu-dist --name trackchain --version 1.0 \
  --package-id $PKG_ID --sequence 1 --tls --cafile $ORDERER_CA

peer lifecycle chaincode commit -o localhost:7050 \
  --ordererTLSHostnameOverride orderer.example.com \
  --channelID manu-dist --name trackchain --version 1.0 --sequence 1 \
  --tls --cafile $ORDERER_CA \
  --peerAddresses localhost:7051 --tlsRootCertFiles $TN/organizations/peerOrganizations/maker.example.com/peers/peer0.maker.example.com/tls/ca.crt \
  --peerAddresses localhost:9051 --tlsRootCertFiles $TN/organizations/peerOrganizations/wholesaler.example.com/peers/peer0.wholesaler.example.com/tls/ca.crt

peer lifecycle chaincode querycommitted -C manu-dist -n trackchain
