#!/usr/bin/env bash
set -euo pipefail

ROOT="$(pwd)"
echo "Project root: $ROOT"

mkdir -p chaincode/trackchain-js
mkdir -p scripts

# ---- chaincode ----
cat > chaincode/trackchain-js/package.json <<'PKG'
{
  "name": "trackchain-js",
  "version": "1.0.0",
  "main": "index.js",
  "license": "Apache-2.0",
  "dependencies": {
    "fabric-contract-api": "^2.5.0",
    "fabric-shim": "^2.5.0"
  }
}
PKG

cat > chaincode/trackchain-js/index.js <<'CC'
'use strict';

const { Contract } = require('fabric-contract-api');

class trackchainContract extends Contract {
  async _put(ctx, key, obj) {
    await ctx.stub.putState(key, Buffer.from(JSON.stringify(obj)));
  }
  async _get(ctx, key) {
    const b = await ctx.stub.getState(key);
    if (!b || b.length === 0) return null;
    return JSON.parse(b.toString());
  }
  _msp(ctx) {
    return ctx.clientIdentity.getMSPID(); // MakerMSP, WholesalerMSP, RetailerMSP
  }

  // Product { productId, sku, desc, ownerMSP, status: 'CREATED'|'IN_TRANSIT'|'DELIVERED' }
  // Shipment { shipmentId, productId, fromMSP, toMSP, status: 'CREATED'|'RECEIVED', ts }

  async CreateProduct(ctx, productId, sku, description) {
    if (!productId) throw new Error('productId required');
    const key = ctx.stub.createCompositeKey('product', [productId]);
    const existing = await this._get(ctx, key);
    if (existing) throw new Error('Product already exists');

    const ownerMSP = this._msp(ctx);
    const prod = { productId, sku, desc: description, ownerMSP, status: 'CREATED' };
    await this._put(ctx, key, prod);
  }

  async CreateShipment(ctx, shipmentId, productId, toMSP) {
    if (!shipmentId || !productId || !toMSP) throw new Error('shipmentId, productId, toMSP required');
    const pKey = ctx.stub.createCompositeKey('product', [productId]);
    const prod = await this._get(ctx, pKey);
    if (!prod) throw new Error('Product not found');

    const caller = this._msp(ctx);
    if (prod.ownerMSP !== caller) throw new Error('Only current owner can create a shipment');

    const sKey = ctx.stub.createCompositeKey('shipment', [shipmentId]);
    const existing = await this._get(ctx, sKey);
    if (existing) throw new Error('Shipment already exists');

    const ship = { shipmentId, productId, fromMSP: caller, toMSP, status: 'CREATED', ts: Date.now() };
    prod.status = 'IN_TRANSIT';
    await this._put(ctx, sKey, ship);
    await this._put(ctx, pKey, prod);
  }

  async ReceiveShipment(ctx, shipmentId) {
    if (!shipmentId) throw new Error('shipmentId required');

    const sKey = ctx.stub.createCompositeKey('shipment', [shipmentId]);
    const ship = await this._get(ctx, sKey);
    if (!ship) throw new Error('Shipment not found');

    const caller = this._msp(ctx);
    if (ship.toMSP !== caller) throw new Error('Only intended receiver can accept');

    ship.status = 'RECEIVED';
    ship.ts = Date.now();
    await this._put(ctx, sKey, ship);

    const pKey = ctx.stub.createCompositeKey('product', [ship.productId]);
    const prod = await this._get(ctx, pKey);
    if (!prod) throw new Error('Linked product not found');

    prod.ownerMSP = caller;
    prod.status = (caller === 'RetailerMSP') ? 'DELIVERED' : 'IN_TRANSIT';
    await this._put(ctx, pKey, prod);
  }

  async GetProduct(ctx, productId) {
    const key = ctx.stub.createCompositeKey('product', [productId]);
    const prod = await this._get(ctx, key);
    if (!prod) throw new Error('Product not found');
    return JSON.stringify(prod);
  }

  async GetProductHistory(ctx, productId) {
    const key = ctx.stub.createCompositeKey('product', [productId]);
    const iter = await ctx.stub.getHistoryForKey(key);
    const out = [];
    for await (const r of iter) {
      out.push({
        txId: r.txId,
        isDelete: r.isDelete,
        value: r.value && r.value.toString(),
        timestamp: r.timestamp && (r.timestamp.seconds && r.timestamp.seconds.low)
      });
    }
    return JSON.stringify(out);
  }
}

module.exports.contracts = [trackchainContract];
CC

# ---- helper scripts ----
cat > scripts/env_exports.sh <<'ENV'
export PATH=$PATH:$HOME/fabric-samples/bin
export ORDERER_CA=$HOME/fabric-samples/test-network/organizations/ordererOrganizations/example.com/orderers/orderer.example.com/msp/tlscacerts/tlsca.example.com-cert.pem
ENV

cat > scripts/start_testnet.sh <<'STN'
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/env_exports.sh"
cd "$HOME/fabric-samples/test-network"
./network.sh down
./network.sh up createChannel -c main-supply
STN
chmod +x scripts/start_testnet.sh

cat > scripts/add_retailer.sh <<'A3'
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/env_exports.sh"
cd "$HOME/fabric-samples/test-network/addOrg3"
./addOrg3.sh up -c main-supply -s couchdb
A3
chmod +x scripts/add_retailer.sh

cat > scripts/create_manu_dist.sh <<'CMD'
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/env_exports.sh"
TN="$HOME/fabric-samples/test-network"
cd "$TN"

mkdir -p channel-artifacts
configtxgen -profile TwoOrgsApplicationGenesis \
  -outputCreateChannelTx ./channel-artifacts/manu-dist.tx \
  -channelID manu-dist

# Org1 env
export CORE_PEER_LOCALMSPID=MakerMSP
export CORE_PEER_ADDRESS=localhost:7051
export CORE_PEER_MSPCONFIGPATH=$TN/organizations/peerOrganizations/maker.example.com/users/Admin@maker.example.com/msp
export CORE_PEER_TLS_ROOTCERT_FILE=$TN/organizations/peerOrganizations/maker.example.com/peers/peer0.maker.example.com/tls/ca.crt

peer channel create -o localhost:7050 --ordererTLSHostnameOverride orderer.example.com \
  -c manu-dist -f ./channel-artifacts/manu-dist.tx \
  --tls --cafile $ORDERER_CA \
  --outputBlock ./manu-dist.block

peer channel join -b ./manu-dist.block

# Org2 env
export CORE_PEER_LOCALMSPID=WholesalerMSP
export CORE_PEER_ADDRESS=localhost:9051
export CORE_PEER_MSPCONFIGPATH=$TN/organizations/peerOrganizations/wholesaler.example.com/users/Admin@wholesaler.example.com/msp
export CORE_PEER_TLS_ROOTCERT_FILE=$TN/organizations/peerOrganizations/wholesaler.example.com/peers/peer0.wholesaler.example.com/tls/ca.crt

peer channel join -b ./manu-dist.block
CMD
chmod +x scripts/create_manu_dist.sh

cat > scripts/deploy_cc_main.sh <<'DCG'
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/env_exports.sh"
TN="$HOME/fabric-samples/test-network"
cd "$TN"
# try absolute project path under Desktop, fallback to another common path
./network.sh deployCC -c main-supply -ccn trackchain -ccp "$HOME/Desktop/BC Project/chaincode/trackchain-js" -ccl javascript
DCG
chmod +x scripts/deploy_cc_main.sh

cat > scripts/deploy_cc_manudist.sh <<'DMD'
#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/env_exports.sh"
TN="$HOME/fabric-samples/test-network"
cd "$TN"

peer lifecycle chaincode package trackchain.tgz \
  --path "$HOME/Desktop/BC Project/chaincode/trackchain-js" \
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
DMD
chmod +x scripts/deploy_cc_manudist.sh

cat > scripts/demo_flow.sh <<'DEM'
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
DEM
chmod +x scripts/demo_flow.sh

cat > README.txt <<'R'
RUN ORDER (Kali):
1) bash setup_kali_fabric.sh
   (then open a new terminal or: source ~/.bashrc ; newgrp docker)

2) bash scripts/start_testnet.sh
3) bash scripts/add_retailer.sh
4) bash scripts/create_manu_dist.sh
5) bash scripts/deploy_cc_main.sh
6) bash scripts/deploy_cc_manudist.sh
7) bash scripts/demo_flow.sh
R

echo "✅ Project files created."
