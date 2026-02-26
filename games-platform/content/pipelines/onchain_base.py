#!/usr/bin/env python3
"""
Base Network On-Chain Data Analysis Pipeline

Fetches recent transactions from Base network, identifies interesting patterns,
and generates activity reports in JSON and Markdown formats.

Features:
- Large transfer detection (ETH and token transfers)
- New contract deployment tracking
- DEX swap volume spike analysis
- Whale wallet monitoring

Usage:
    python onchain_base.py [--blocks N] [--output-dir DIR]

Requirements:
    pip install requests web3 python-dotenv

Environment Variables:
    BASE_RPC_URL - Custom RPC endpoint (optional, defaults to public nodes)
    BASESCAN_API_KEY - Basescan API key for enhanced data (optional)
"""

import argparse
import json
import os
import sys
import time
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from decimal import Decimal
from pathlib import Path
from typing import Optional
from urllib.parse import urljoin

import requests

# ============================================================================
# Configuration
# ============================================================================

# Public RPC endpoints for Base (fallback chain)
BASE_RPC_ENDPOINTS = [
    "https://base-rpc.publicnode.com",
    "https://base.llamarpc.com",
    "https://base.drpc.org",
]

# Basescan API
BASESCAN_API_URL = "https://api.basescan.org/api"

# Base Chain ID
BASE_CHAIN_ID = 8453

# DEX Swap Event Signatures (topic0)
DEX_EVENTS = {
    # Uniswap V2 / SushiSwap / Aerodrome (Solidly fork)
    "0xd78ad95fa46c994b6551d0da85fc275fe613ce37657fb8d5e3d130840159d822": {
        "name": "Swap",
        "dex": "UniswapV2/Aerodrome",
        "description": "Token swap event",
    },
    # Uniswap V3 Swap
    "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67": {
        "name": "Swap",
        "dex": "UniswapV3",
        "description": "V3 token swap event",
    },
    # Aerodrome specific (same as Uniswap V2 but on Base)
    "0x1c411e9a96e071241c2f21f7726b17ae89e3cab4c78be50e062b03a9fffbbad1": {
        "name": "Sync",
        "dex": "Aerodrome",
        "description": "Pool sync event",
    },
}

# ERC20 Transfer event
TRANSFER_EVENT_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

# Contract creation detection (to address is null/0x)
CONTRACT_CREATION_TOPIC = "0x0000000000000000000000000000000000000000000000000000000000000000"

# Thresholds
LARGE_TRANSFER_ETH = Decimal("10")  # 10 ETH
LARGE_TRANSFER_USD = Decimal("10000")  # $10k equivalent
WHALE_THRESHOLD_ETH = Decimal("100")  # 100 ETH balance
VOLUME_SPIKE_MULTIPLIER = 2.0  # 2x average = spike

# Known DEX router addresses on Base (for filtering)
DEX_ROUTERS = {
    "0x4752ba5dbc23f44d87826276bf6fd6b1c372ad24": "Uniswap V3 Router",
    "0x3fc91a3afd70395cd496c647d5a6cc9d4b2b7fad": "Uniswap V3 Universal Router",
    "0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43": "Aerodrome Router",
    "0x6BDED42c6DA8FBf0d2bA91B2cd47b3aD1D661f2a": "BaseSwap Router",
    "0x327Df1E6de05895d2ab08513aaDD9313Fe505d86": "AlienBase Router",
    "0x8c1A3cF8f83074169FE5E1d5f880073e3B3F0b5b": "SwapBased Router",
}

# Known token addresses on Base
KNOWN_TOKENS = {
    "0x4200000000000000000000000000000000000006": {"symbol": "WETH", "decimals": 18},
    "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913": {"symbol": "USDC", "decimals": 6},
    "0x50c5725949A6F0c72E6C4a641F24049A917DB0Cb": {"symbol": "DAI", "decimals": 18},
    "0xB6fe221Fe9EeF5aBa221c348bA20A40986cF5915": {"symbol": "cbETH", "decimals": 18},
    "0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22": {"symbol": "cbETH", "decimals": 18},
    "0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A": {"symbol": "weETH", "decimals": 18},
    "0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452": {"symbol": "wstETH", "decimals": 18},
    "0x9e1028F5F1D5eDE59748FFceE5532509976840E0": {"symbol": "COMP", "decimals": 18},
    "0xA88594D404727625A9437C3f886C7643872296AE": {"symbol": "WELL", "decimals": 18},
    "0x940181a94A35A4569E4529A3CDfB74e38FD98631": {"symbol": "AERO", "decimals": 18},
    "0x368181499736d0c83CC3451dE8c57a348e2B5820": {"symbol": "Brett", "decimals": 18},
}


# ============================================================================
# Data Classes
# ============================================================================

@dataclass
class Transaction:
    """Represents a blockchain transaction."""
    hash: str
    block_number: int
    timestamp: datetime
    from_address: str
    to_address: Optional[str]
    value_eth: Decimal
    gas_used: int
    gas_price_gwei: Decimal
    is_contract_creation: bool = False
    input_data: str = ""
    
    def to_dict(self) -> dict:
        return {
            "hash": self.hash,
            "block_number": self.block_number,
            "timestamp": self.timestamp.isoformat(),
            "from_address": self.from_address,
            "to_address": self.to_address,
            "value_eth": str(self.value_eth),
            "gas_used": self.gas_used,
            "gas_price_gwei": str(self.gas_price_gwei),
            "is_contract_creation": self.is_contract_creation,
        }


@dataclass
class LargeTransfer:
    """Represents a large value transfer."""
    tx_hash: str
    block_number: int
    timestamp: datetime
    from_address: str
    to_address: str
    value_eth: Decimal
    token_symbol: Optional[str] = None
    token_amount: Optional[Decimal] = None
    usd_estimate: Optional[Decimal] = None
    
    def to_dict(self) -> dict:
        return {
            "tx_hash": self.tx_hash,
            "block_number": self.block_number,
            "timestamp": self.timestamp.isoformat(),
            "from_address": self.from_address,
            "to_address": self.to_address,
            "value_eth": str(self.value_eth) if self.value_eth else None,
            "token_symbol": self.token_symbol,
            "token_amount": str(self.token_amount) if self.token_amount else None,
            "usd_estimate": str(self.usd_estimate) if self.usd_estimate else None,
        }


@dataclass
class ContractDeployment:
    """Represents a new contract deployment."""
    tx_hash: str
    block_number: int
    timestamp: datetime
    deployer_address: str
    contract_address: Optional[str]
    bytecode_size: int
    creation_value_eth: Decimal
    is_proxy: bool = False
    
    def to_dict(self) -> dict:
        return {
            "tx_hash": self.tx_hash,
            "block_number": self.block_number,
            "timestamp": self.timestamp.isoformat(),
            "deployer_address": self.deployer_address,
            "contract_address": self.contract_address,
            "bytecode_size": self.bytecode_size,
            "creation_value_eth": str(self.creation_value_eth),
            "is_proxy": self.is_proxy,
        }


@dataclass
class DEXSwap:
    """Represents a DEX swap transaction."""
    tx_hash: str
    block_number: int
    timestamp: datetime
    dex_name: str
    pool_address: str
    sender: str
    recipient: str
    token_in: Optional[str]
    token_out: Optional[str]
    amount_in: Optional[Decimal]
    amount_out: Optional[Decimal]
    
    def to_dict(self) -> dict:
        return {
            "tx_hash": self.tx_hash,
            "block_number": self.block_number,
            "timestamp": self.timestamp.isoformat(),
            "dex_name": self.dex_name,
            "pool_address": self.pool_address,
            "sender": self.sender,
            "recipient": self.recipient,
            "token_in": self.token_in,
            "token_out": self.token_out,
            "amount_in": str(self.amount_in) if self.amount_in else None,
            "amount_out": str(self.amount_out) if self.amount_out else None,
        }


@dataclass
class WalletActivity:
    """Aggregated activity for a wallet."""
    address: str
    tx_count: int = 0
    total_sent_eth: Decimal = field(default_factory=lambda: Decimal("0"))
    total_received_eth: Decimal = field(default_factory=lambda: Decimal("0"))
    contract_deployments: int = 0
    dex_swaps: int = 0
    is_whale: bool = False
    
    def to_dict(self) -> dict:
        return {
            "address": self.address,
            "tx_count": self.tx_count,
            "total_sent_eth": str(self.total_sent_eth),
            "total_received_eth": str(self.total_received_eth),
            "contract_deployments": self.contract_deployments,
            "dex_swaps": self.dex_swaps,
            "is_whale": self.is_whale,
        }


@dataclass
class OnChainReport:
    """Complete on-chain activity report."""
    generated_at: datetime
    start_block: int
    end_block: int
    block_range: int
    total_transactions: int
    
    # Patterns
    large_transfers: list[LargeTransfer] = field(default_factory=list)
    contract_deployments: list[ContractDeployment] = field(default_factory=list)
    dex_swaps: list[DEXSwap] = field(default_factory=list)
    
    # Aggregations
    top_active_wallets: list[WalletActivity] = field(default_factory=list)
    dex_volume_by_protocol: dict[str, Decimal] = field(default_factory=dict)
    
    # Metadata
    eth_price_usd: Optional[Decimal] = None
    
    def to_dict(self) -> dict:
        return {
            "generated_at": self.generated_at.isoformat(),
            "start_block": self.start_block,
            "end_block": self.end_block,
            "block_range": self.block_range,
            "total_transactions": self.total_transactions,
            "eth_price_usd": str(self.eth_price_usd) if self.eth_price_usd else None,
            "large_transfers": [t.to_dict() for t in self.large_transfers],
            "contract_deployments": [c.to_dict() for c in self.contract_deployments],
            "dex_swaps": [s.to_dict() for s in self.dex_swaps],
            "top_active_wallets": [w.to_dict() for w in self.top_active_wallets],
            "dex_volume_by_protocol": {k: str(v) for k, v in self.dex_volume_by_protocol.items()},
            "summary": self._generate_summary(),
        }
    
    def _generate_summary(self) -> dict:
        return {
            "large_transfers_count": len(self.large_transfers),
            "contract_deployments_count": len(self.contract_deployments),
            "dex_swaps_count": len(self.dex_swaps),
            "whale_wallets_count": sum(1 for w in self.top_active_wallets if w.is_whale),
            "total_volume_eth": str(sum(
                (t.value_eth for t in self.large_transfers),
                Decimal("0")
            )),
        }


# ============================================================================
# RPC Client
# ============================================================================

class BaseRPCClient:
    """JSON-RPC client for Base network with fallback endpoints."""
    
    def __init__(self, custom_rpc: Optional[str] = None):
        self.endpoints = []
        if custom_rpc:
            self.endpoints.append(custom_rpc)
        self.endpoints.extend(BASE_RPC_ENDPOINTS)
        self.current_endpoint_idx = 0
        self.session = requests.Session()
        self.session.headers.update({
            "Content-Type": "application/json",
        })
    
    def _get_rpc_url(self) -> str:
        return self.endpoints[self.current_endpoint_idx % len(self.endpoints)]
    
    def _rotate_endpoint(self):
        """Rotate to next endpoint on failure."""
        self.current_endpoint_idx += 1
        if self.current_endpoint_idx >= len(self.endpoints):
            self.current_endpoint_idx = 0
    
    def call(self, method: str, params: list = None, timeout: int = 30) -> dict:
        """Make a JSON-RPC call with retry logic."""
        payload = {
            "jsonrpc": "2.0",
            "method": method,
            "params": params or [],
            "id": 1,
        }
        
        max_retries = len(self.endpoints)
        last_error = None
        
        for attempt in range(max_retries):
            try:
                url = self._get_rpc_url()
                response = self.session.post(
                    url,
                    json=payload,
                    timeout=timeout
                )
                response.raise_for_status()
                data = response.json()
                
                if "error" in data:
                    raise RPCError(f"RPC error: {data['error']}")
                
                return data["result"]
                
            except (requests.RequestException, RPCError) as e:
                last_error = e
                self._rotate_endpoint()
                time.sleep(0.5 * (attempt + 1))  # Exponential backoff
        
        raise RPCError(f"All RPC endpoints failed. Last error: {last_error}")
    
    def get_block_number(self) -> int:
        """Get the latest block number."""
        result = self.call("eth_blockNumber")
        return int(result, 16)
    
    def get_block(self, block_number: int, full_transactions: bool = True) -> dict:
        """Get block data by number."""
        hex_num = hex(block_number)
        return self.call("eth_getBlockByNumber", [hex_num, full_transactions])
    
    def get_transaction_receipt(self, tx_hash: str) -> dict:
        """Get transaction receipt."""
        return self.call("eth_getTransactionReceipt", [tx_hash])
    
    def get_logs(self, from_block: int, to_block: int, topics: list = None, address: str = None) -> list:
        """Get event logs for a block range."""
        params = {
            "fromBlock": hex(from_block),
            "toBlock": hex(to_block),
        }
        if topics:
            params["topics"] = topics
        if address:
            params["address"] = address
        
        return self.call("eth_getLogs", [params])
    
    def get_balance(self, address: str, block_number: int = None) -> Decimal:
        """Get ETH balance for an address."""
        block = hex(block_number) if block_number else "latest"
        result = self.call("eth_getBalance", [address, block])
        return Decimal(int(result, 16)) / Decimal(10**18)


class RPCError(Exception):
    """RPC client error."""
    pass


# ============================================================================
# Basescan API Client
# ============================================================================

class BasescanClient:
    """Basescan API client for enhanced data."""
    
    def __init__(self, api_key: Optional[str] = None):
        self.api_key = api_key or os.getenv("BASESCAN_API_KEY")
        self.base_url = BASESCAN_API_URL
        self.session = requests.Session()
        self._last_call_time = 0
        self._min_interval = 0.25  # 4 calls per second max (free tier: 5/sec)
    
    def _rate_limit(self):
        """Enforce rate limiting."""
        elapsed = time.time() - self._last_call_time
        if elapsed < self._min_interval:
            time.sleep(self._min_interval - elapsed)
        self._last_call_time = time.time()
    
    def _call(self, module: str, action: str, **params) -> dict:
        """Make an API call to Basescan."""
        if not self.api_key:
            raise BasescanError("API key required. Set BASESCAN_API_KEY env var.")
        
        self._rate_limit()
        
        url_params = {
            "module": module,
            "action": action,
            "apikey": self.api_key,
            **params
        }
        
        response = self.session.get(self.base_url, params=url_params, timeout=30)
        response.raise_for_status()
        data = response.json()
        
        if data.get("status") != "1" and data.get("message") != "OK":
            # Some valid responses have status "0" but contain data
            if "result" not in data:
                raise BasescanError(f"API error: {data.get('message', 'Unknown error')}")
        
        return data.get("result", [])
    
    def get_transactions(self, address: str, start_block: int = 0, end_block: int = 99999999) -> list:
        """Get transactions for an address."""
        return self._call(
            "account",
            "txlist",
            address=address,
            startblock=start_block,
            endblock=end_block,
            sort="desc"
        )
    
    def get_erc20_transfers(self, address: str = None, contract: str = None, 
                            start_block: int = 0, end_block: int = 99999999) -> list:
        """Get ERC20 token transfers."""
        params = {
            "startblock": start_block,
            "endblock": end_block,
            "sort": "desc",
        }
        if address:
            params["address"] = address
        if contract:
            params["contractaddress"] = contract
        
        return self._call("account", "tokentx", **params)
    
    def get_contract_abi(self, address: str) -> dict:
        """Get contract ABI if verified."""
        result = self._call("contract", "getabi", address=address)
        if isinstance(result, str):
            return json.loads(result)
        return result
    
    def get_contract_source(self, address: str) -> dict:
        """Get contract source code if verified."""
        return self._call("contract", "getsourcecode", address=address)
    
    def get_logs(self, from_block: int, to_block: int, topic0: str = None, 
                 address: str = None) -> list:
        """Get event logs."""
        params = {
            "fromBlock": from_block,
            "toBlock": to_block,
        }
        if topic0:
            params["topic0"] = topic0
        if address:
            params["address"] = address
        
        return self._call("logs", "getLogs", **params)


class BasescanError(Exception):
    """Basescan API error."""
    pass


# ============================================================================
# Analysis Engine
# ============================================================================

class OnChainAnalyzer:
    """Analyzes Base network on-chain data."""
    
    def __init__(self, rpc_client: BaseRPCClient, basescan: Optional[BasescanClient] = None):
        self.rpc = rpc_client
        self.basescan = basescan
        self.eth_price_usd: Optional[Decimal] = None
    
    def fetch_eth_price(self) -> Decimal:
        """Fetch current ETH price (simplified - would use price oracle in production)."""
        # In production, fetch from Chainlink or DEX oracle
        # For now, use a reasonable estimate or fetch from CoinGecko
        try:
            response = requests.get(
                "https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd",
                timeout=10
            )
            data = response.json()
            self.eth_price_usd = Decimal(str(data["ethereum"]["usd"]))
        except Exception:
            self.eth_price_usd = Decimal("3000")  # Fallback estimate
        
        return self.eth_price_usd
    
    def analyze_blocks(self, start_block: int, end_block: int) -> OnChainReport:
        """Analyze a range of blocks for patterns."""
        report = OnChainReport(
            generated_at=datetime.now(timezone.utc),
            start_block=start_block,
            end_block=end_block,
            block_range=end_block - start_block + 1,
            total_transactions=0,
        )
        
        # Fetch ETH price for USD estimates
        report.eth_price_usd = self.fetch_eth_price()
        
        # Track wallet activity
        wallet_activity: dict[str, WalletActivity] = {}
        dex_volume: dict[str, Decimal] = {}
        
        print(f"Analyzing blocks {start_block} to {end_block}...")
        
        for block_num in range(start_block, end_block + 1):
            if block_num % 100 == 0:
                print(f"  Processing block {block_num}...")
            
            try:
                block = self.rpc.get_block(block_num, full_transactions=True)
                if not block:
                    continue
                
                timestamp = datetime.fromtimestamp(int(block["timestamp"], 16), tz=timezone.utc)
                transactions = block.get("transactions", [])
                report.total_transactions += len(transactions)
                
                for tx in transactions:
                    self._analyze_transaction(
                        tx, block_num, timestamp, report,
                        wallet_activity, dex_volume
                    )
                
                # Small delay to be nice to public RPCs
                time.sleep(0.05)
                
            except Exception as e:
                print(f"  Error processing block {block_num}: {e}")
                continue
        
        # Post-processing
        report.top_active_wallets = sorted(
            wallet_activity.values(),
            key=lambda w: w.tx_count,
            reverse=True
        )[:20]  # Top 20
        
        report.dex_volume_by_protocol = dex_volume
        
        return report
    
    def _analyze_transaction(self, tx: dict, block_num: int, timestamp: datetime,
                            report: OnChainReport, wallet_activity: dict,
                            dex_volume: dict):
        """Analyze a single transaction for patterns."""
        tx_hash = tx.get("hash", "")
        from_addr = tx.get("from", "").lower()
        to_addr = tx.get("to", "").lower() if tx.get("to") else None
        value_wei = int(tx.get("value", "0x0"), 16)
        value_eth = Decimal(value_wei) / Decimal(10**18)
        
        gas_price = int(tx.get("gasPrice", "0x0"), 16)
        gas_price_gwei = Decimal(gas_price) / Decimal(10**9)
        
        # Update wallet activity
        for addr in [from_addr, to_addr]:
            if addr and addr not in wallet_activity:
                wallet_activity[addr] = WalletActivity(address=addr)
        
        if from_addr:
            wallet_activity[from_addr].tx_count += 1
            wallet_activity[from_addr].total_sent_eth += value_eth
        
        if to_addr:
            wallet_activity[to_addr].tx_count += 1
            wallet_activity[to_addr].total_received_eth += value_eth
        
        # Check for contract creation
        if not to_addr:
            self._handle_contract_creation(
                tx, block_num, timestamp, value_eth, report
            )
            if from_addr:
                wallet_activity[from_addr].contract_deployments += 1
        
        # Check for large transfers
        if value_eth >= LARGE_TRANSFER_ETH:
            self._handle_large_transfer(
                tx_hash, block_num, timestamp, from_addr, to_addr or "",
                value_eth, report
            )
        
        # Check for DEX interactions
        if to_addr and to_addr in DEX_ROUTERS:
            self._handle_dex_interaction(
                tx, block_num, timestamp, to_addr, report,
                wallet_activity, dex_volume
            )
    
    def _handle_contract_creation(self, tx: dict, block_num: int, 
                                   timestamp: datetime, value_eth: Decimal,
                                   report: OnChainReport):
        """Handle contract deployment detection."""
        tx_hash = tx.get("hash", "")
        from_addr = tx.get("from", "").lower()
        input_data = tx.get("input", "")
        
        # Try to get contract address from receipt
        contract_address = None
        try:
            receipt = self.rpc.get_transaction_receipt(tx_hash)
            if receipt:
                contract_address = receipt.get("contractAddress", "").lower()
        except Exception:
            pass
        
        # Check for proxy pattern
        is_proxy = any(pattern in input_data.lower() for pattern in [
            "delegate", "implementation", "proxy"
        ])
        
        deployment = ContractDeployment(
            tx_hash=tx_hash,
            block_number=block_num,
            timestamp=timestamp,
            deployer_address=from_addr,
            contract_address=contract_address,
            bytecode_size=len(input_data) // 2 - 1 if input_data else 0,
            creation_value_eth=value_eth,
            is_proxy=is_proxy,
        )
        
        report.contract_deployments.append(deployment)
    
    def _handle_large_transfer(self, tx_hash: str, block_num: int,
                                timestamp: datetime, from_addr: str,
                                to_addr: str, value_eth: Decimal,
                                report: OnChainReport):
        """Handle large transfer detection."""
        usd_estimate = None
        if report.eth_price_usd:
            usd_estimate = value_eth * report.eth_price_usd
        
        transfer = LargeTransfer(
            tx_hash=tx_hash,
            block_number=block_num,
            timestamp=timestamp,
            from_address=from_addr,
            to_address=to_addr,
            value_eth=value_eth,
            usd_estimate=usd_estimate,
        )
        
        report.large_transfers.append(transfer)
    
    def _handle_dex_interaction(self, tx: dict, block_num: int,
                                 timestamp: datetime, router_addr: str,
                                 report: OnChainReport,
                                 wallet_activity: dict,
                                 dex_volume: dict):
        """Handle DEX interaction detection."""
        tx_hash = tx.get("hash", "")
        from_addr = tx.get("from", "").lower()
        input_data = tx.get("input", "")
        value_eth = Decimal(int(tx.get("value", "0x0"), 16)) / Decimal(10**18)
        
        dex_name = DEX_ROUTERS.get(router_addr, "Unknown DEX")
        
        # Track DEX volume
        if dex_name not in dex_volume:
            dex_volume[dex_name] = Decimal("0")
        dex_volume[dex_name] += value_eth
        
        # Update wallet activity
        if from_addr in wallet_activity:
            wallet_activity[from_addr].dex_swaps += 1
        
        # Try to decode swap details from input data
        # This is simplified - full decoding would require ABI
        swap = DEXSwap(
            tx_hash=tx_hash,
            block_number=block_num,
            timestamp=timestamp,
            dex_name=dex_name,
            pool_address=router_addr,
            sender=from_addr,
            recipient=from_addr,  # Simplified
            token_in=None,  # Would need full decoding
            token_out=None,
            amount_in=value_eth if value_eth > 0 else None,
            amount_out=None,
        )
        
        report.dex_swaps.append(swap)


# ============================================================================
# Report Generators
# ============================================================================

class ReportGenerator:
    """Generates output reports in various formats."""
    
    def __init__(self, report: OnChainReport):
        self.report = report
    
    def to_json(self, pretty: bool = True) -> str:
        """Generate JSON report."""
        data = self.report.to_dict()
        if pretty:
            return json.dumps(data, indent=2, default=str)
        return json.dumps(data, default=str)
    
    def to_markdown(self) -> str:
        """Generate Markdown report."""
        r = self.report
        summary = r._generate_summary()
        
        lines = [
            "# Base Network On-Chain Activity Report",
            "",
            f"**Generated:** {r.generated_at.strftime('%Y-%m-%d %H:%M:%S UTC')}",
            f"**Block Range:** {r.start_block:,} - {r.end_block:,} ({r.block_range:,} blocks)",
            f"**Total Transactions:** {r.total_transactions:,}",
            "",
            "---",
            "",
            "## Summary",
            "",
            f"| Metric | Value |",
            f"|--------|-------|",
            f"| Large Transfers | {summary['large_transfers_count']} |",
            f"| Contract Deployments | {summary['contract_deployments_count']} |",
            f"| DEX Swaps | {summary['dex_swaps_count']} |",
            f"| Whale Wallets | {summary['whale_wallets_count']} |",
            f"| Total Volume (ETH) | {summary['total_volume_eth']} |",
            "",
        ]
        
        # Large Transfers Section
        lines.extend([
            "## Large Transfers",
            "",
        ])
        
        if r.large_transfers:
            lines.extend([
                "| Time | From | To | Value (ETH) | USD Estimate |",
                "|------|------|-----|-------------|--------------|",
            ])
            for t in sorted(r.large_transfers, key=lambda x: x.value_eth, reverse=True)[:20]:
                usd_str = f"${float(t.usd_estimate):,.2f}" if t.usd_estimate else "N/A"
                from_short = f"{t.from_address[:6]}...{t.from_address[-4:]}"
                to_short = f"{t.to_address[:6]}...{t.to_address[-4:]}"
                lines.append(
                    f"| {t.timestamp.strftime('%H:%M:%S')} | {from_short} | {to_short} | "
                    f"{float(t.value_eth):.4f} | {usd_str} |"
                )
        else:
            lines.append("*No large transfers detected in this block range.*")
        
        lines.append("")
        
        # Contract Deployments Section
        lines.extend([
            "## Contract Deployments",
            "",
        ])
        
        if r.contract_deployments:
            lines.extend([
                "| Time | Deployer | Contract | Bytecode Size | Is Proxy |",
                "|------|----------|----------|---------------|----------|",
            ])
            for c in sorted(r.contract_deployments, key=lambda x: x.block_number, reverse=True)[:15]:
                deployer_short = f"{c.deployer_address[:6]}...{c.deployer_address[-4:]}"
                contract_short = f"{c.contract_address[:6]}...{c.contract_address[-4:]}" if c.contract_address else "Pending"
                proxy_str = "✓" if c.is_proxy else ""
                lines.append(
                    f"| {c.timestamp.strftime('%H:%M:%S')} | {deployer_short} | {contract_short} | "
                    f"{c.bytecode_size:,} | {proxy_str} |"
                )
        else:
            lines.append("*No contract deployments detected in this block range.*")
        
        lines.append("")
        
        # DEX Activity Section
        lines.extend([
            "## DEX Activity",
            "",
        ])
        
        if r.dex_swaps:
            lines.extend([
                "### Volume by Protocol",
                "",
                "| DEX | Volume (ETH) |",
                "|-----|--------------|",
            ])
            for dex, volume in sorted(r.dex_volume_by_protocol.items(), key=lambda x: x[1], reverse=True):
                lines.append(f"| {dex} | {float(volume):.4f} |")
            
            lines.extend([
                "",
                "### Recent Swaps",
                "",
                "| Time | DEX | Sender | Value (ETH) |",
                "|------|-----|--------|-------------|",
            ])
            for s in sorted(r.dex_swaps, key=lambda x: x.timestamp, reverse=True)[:15]:
                sender_short = f"{s.sender[:6]}...{s.sender[-4:]}"
                value_str = f"{float(s.amount_in):.4f}" if s.amount_in else "N/A"
                lines.append(
                    f"| {s.timestamp.strftime('%H:%M:%S')} | {s.dex_name} | {sender_short} | {value_str} |"
                )
        else:
            lines.append("*No DEX activity detected in this block range.*")
        
        lines.append("")
        
        # Top Active Wallets
        lines.extend([
            "## Top Active Wallets",
            "",
        ])
        
        if r.top_active_wallets:
            lines.extend([
                "| Address | TX Count | Sent (ETH) | Received (ETH) | Deployments | Swaps |",
                "|---------|----------|------------|----------------|-------------|-------|",
            ])
            for w in r.top_active_wallets[:15]:
                addr_short = f"{w.address[:6]}...{w.address[-4:]}"
                whale_marker = " 🐋" if w.is_whale else ""
                lines.append(
                    f"| {addr_short}{whale_marker} | {w.tx_count} | {float(w.total_sent_eth):.4f} | "
                    f"{float(w.total_received_eth):.4f} | {w.contract_deployments} | {w.dex_swaps} |"
                )
            lines.append("")
            lines.append("*🐋 = Whale wallet (>100 ETH balance)*")
        else:
            lines.append("*No wallet activity data available.*")
        
        lines.extend([
            "",
            "---",
            "",
            "## Methodology",
            "",
            "This report analyzes on-chain data from the Base L2 network.",
            "",
            "**Large Transfer Threshold:** ≥10 ETH  ",
            "**DEX Detection:** Router contract interactions  ",
            "**Contract Detection:** Transactions with null `to` address  ",
            "**Price Data:** CoinGecko API (ETH/USD)",
            "",
            f"*Report generated by Base On-Chain Analyzer*",
        ])
        
        return "\n".join(lines)
    
    def save(self, output_dir: Path, base_name: str = "base_onchain_report"):
        """Save reports to files."""
        output_dir = Path(output_dir)
        output_dir.mkdir(parents=True, exist_ok=True)
        
        timestamp = self.report.generated_at.strftime("%Y%m%d_%H%M%S")
        
        # Save JSON
        json_path = output_dir / f"{base_name}_{timestamp}.json"
        with open(json_path, "w") as f:
            f.write(self.to_json())
        print(f"Saved JSON report: {json_path}")
        
        # Save Markdown
        md_path = output_dir / f"{base_name}_{timestamp}.md"
        with open(md_path, "w") as f:
            f.write(self.to_markdown())
        print(f"Saved Markdown report: {md_path}")
        
        # Also save as latest
        latest_json = output_dir / f"{base_name}_latest.json"
        with open(latest_json, "w") as f:
            f.write(self.to_json())
        
        latest_md = output_dir / f"{base_name}_latest.md"
        with open(latest_md, "w") as f:
            f.write(self.to_markdown())
        
        return json_path, md_path


# ============================================================================
# CLI
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description="Base Network On-Chain Data Analysis Pipeline"
    )
    parser.add_argument(
        "--blocks",
        type=int,
        default=100,
        help="Number of recent blocks to analyze (default: 100)"
    )
    parser.add_argument(
        "--start-block",
        type=int,
        help="Starting block number (overrides --blocks)"
    )
    parser.add_argument(
        "--end-block",
        type=int,
        help="Ending block number (overrides --blocks)"
    )
    parser.add_argument(
        "--rpc-url",
        help="Custom RPC endpoint URL"
    )
    parser.add_argument(
        "--basescan-key",
        help="Basescan API key"
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("./onchain_reports"),
        help="Output directory for reports (default: ./onchain_reports)"
    )
    parser.add_argument(
        "--no-basescan",
        action="store_true",
        help="Skip Basescan API (RPC-only mode)"
    )
    
    args = parser.parse_args()
    
    # Initialize clients
    rpc_url = args.rpc_url or os.getenv("BASE_RPC_URL")
    rpc_client = BaseRPCClient(custom_rpc=rpc_url)
    
    basescan = None
    if not args.no_basescan:
        api_key = args.basescan_key or os.getenv("BASESCAN_API_KEY")
        if api_key:
            basescan = BasescanClient(api_key=api_key)
            print("✓ Basescan API enabled")
        else:
            print("⚠ Basescan API key not provided. Running in RPC-only mode.")
            print("  Set BASESCAN_API_KEY for enhanced data.")
    
    # Determine block range
    try:
        latest_block = rpc_client.get_block_number()
        print(f"✓ Connected to Base network (latest block: {latest_block:,})")
    except RPCError as e:
        print(f"✗ Failed to connect to Base network: {e}")
        sys.exit(1)
    
    if args.start_block and args.end_block:
        start_block = args.start_block
        end_block = args.end_block
    elif args.start_block:
        start_block = args.start_block
        end_block = min(start_block + args.blocks - 1, latest_block)
    else:
        end_block = latest_block
        start_block = max(end_block - args.blocks + 1, 0)
    
    if end_block > latest_block:
        print(f"⚠ End block {end_block} is ahead of latest block {latest_block}")
        end_block = latest_block
    
    if start_block < 0:
        start_block = 0
    
    print(f"\nAnalyzing blocks {start_block:,} to {end_block:,} ({end_block - start_block + 1:,} blocks)")
    
    # Run analysis
    analyzer = OnChainAnalyzer(rpc_client, basescan)
    
    try:
        report = analyzer.analyze_blocks(start_block, end_block)
    except KeyboardInterrupt:
        print("\n⚠ Analysis interrupted by user")
        sys.exit(1)
    except Exception as e:
        print(f"\n✗ Analysis failed: {e}")
        raise
    
    # Generate and save reports
    print("\nGenerating reports...")
    generator = ReportGenerator(report)
    json_path, md_path = generator.save(args.output_dir)
    
    # Print summary
    summary = report._generate_summary()
    print("\n" + "=" * 50)
    print("ANALYSIS COMPLETE")
    print("=" * 50)
    print(f"Large Transfers:     {summary['large_transfers_count']}")
    print(f"Contract Deployments: {summary['contract_deployments_count']}")
    print(f"DEX Swaps:           {summary['dex_swaps_count']}")
    print(f"Total Volume:        {float(summary['total_volume_eth']):.4f} ETH")
    print("=" * 50)
    print(f"\nReports saved to:")
    print(f"  JSON: {json_path}")
    print(f"  MD:   {md_path}")


if __name__ == "__main__":
    main()
