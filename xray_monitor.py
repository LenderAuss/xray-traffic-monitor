#!/usr/bin/env python3
"""
Xray Traffic Monitor - High-Performance Python Implementation with Baserow
===========================================================================
Version: 4.1 with Baserow Integration
"""

import asyncio
import time
import argparse
import sys
import os
import requests
from typing import Dict, Tuple, Optional
from dataclasses import dataclass, field
from collections import defaultdict
from datetime import datetime

# gRPC imports
import grpc
from grpc import aio as grpc_aio

# ============================================================================
# PROTOBUF DEFINITIONS
# ============================================================================

class StatsServiceStub:
    def __init__(self, channel):
        self.channel = channel
        self.QueryStats = channel.unary_unary(
            '/v2ray.core.app.stats.command.StatsService/QueryStats',
            request_serializer=self._serialize_query_request,
            response_deserializer=self._deserialize_query_response,
        )
    
    @staticmethod
    def _serialize_query_request(request: dict) -> bytes:
        pattern = request.get('pattern', '')
        if not pattern:
            return b''
        pattern_bytes = pattern.encode('utf-8')
        length = len(pattern_bytes)
        length_varint = []
        while length > 127:
            length_varint.append((length & 0x7f) | 0x80)
            length >>= 7
        length_varint.append(length & 0x7f)
        return bytes([0x0a] + length_varint) + pattern_bytes
    
    @staticmethod
    def _deserialize_query_response(response_bytes: bytes) -> dict:
        stats = []
        pos = 0
        
        while pos < len(response_bytes):
            if pos >= len(response_bytes):
                break
            tag = response_bytes[pos]
            pos += 1
            
            field_number = tag >> 3
            wire_type = tag & 0x07
            
            if field_number == 1 and wire_type == 2:
                length, bytes_read = StatsServiceStub._read_varint(response_bytes, pos)
                pos += bytes_read
                stat_data = response_bytes[pos:pos + length]
                pos += length
                stat = StatsServiceStub._parse_stat(stat_data)
                if stat:
                    stats.append(stat)
            else:
                pos = StatsServiceStub._skip_field(response_bytes, pos, wire_type)
        
        return {'stat': stats}
    
    @staticmethod
    def _read_varint(data: bytes, pos: int) -> Tuple[int, int]:
        result = 0
        shift = 0
        bytes_read = 0
        
        while pos + bytes_read < len(data):
            byte = data[pos + bytes_read]
            bytes_read += 1
            result |= (byte & 0x7f) << shift
            if not (byte & 0x80):
                break
            shift += 7
        
        return result, bytes_read
    
    @staticmethod
    def _parse_stat(data: bytes) -> Optional[dict]:
        stat = {}
        pos = 0
        
        while pos < len(data):
            if pos >= len(data):
                break
            tag = data[pos]
            pos += 1
            
            field_number = tag >> 3
            wire_type = tag & 0x07
            
            if field_number == 1 and wire_type == 2:
                length, bytes_read = StatsServiceStub._read_varint(data, pos)
                pos += bytes_read
                stat['name'] = data[pos:pos + length].decode('utf-8', errors='ignore')
                pos += length
            elif field_number == 2 and wire_type == 0:
                value, bytes_read = StatsServiceStub._read_varint(data, pos)
                pos += bytes_read
                stat['value'] = value
            else:
                pos = StatsServiceStub._skip_field(data, pos, wire_type)
        
        return stat if 'name' in stat else None
    
    @staticmethod
    def _skip_field(data: bytes, pos: int, wire_type: int) -> int:
        if wire_type == 0:
            while pos < len(data) and (data[pos] & 0x80):
                pos += 1
            return pos + 1
        elif wire_type == 2:
            length, bytes_read = StatsServiceStub._read_varint(data, pos)
            return pos + bytes_read + length
        else:
            return pos

# ============================================================================
# DATA STRUCTURES
# ============================================================================

@dataclass
class TrafficData:
    uplink: int = 0
    downlink: int = 0
    uplink_speed: float = 0.0
    downlink_speed: float = 0.0
    last_update: float = field(default_factory=time.time)
    
    @property
    def total(self) -> int:
        return self.uplink + self.downlink

# ============================================================================
# XRAY CLIENT
# ============================================================================

class XrayStatsClient:
    def __init__(self, server: str = "127.0.0.1:10085"):
        self.server = server
        self.channel: Optional[grpc_aio.Channel] = None
        self.stub: Optional[StatsServiceStub] = None
        self._connected = False
    
    async def connect(self) -> bool:
        try:
            self.channel = grpc_aio.insecure_channel(self.server)
            self.stub = StatsServiceStub(self.channel)
            await self.channel.channel_ready()
            self._connected = True
            return True
        except Exception as e:
            print(f"❌ Connection error: {e}", file=sys.stderr)
            self._connected = False
            return False
    
    async def disconnect(self):
        if self.channel:
            await self.channel.close()
            self._connected = False
    
    async def query_all_stats(self) -> Dict[str, Dict[str, int]]:
        if not self._connected:
            if not await self.connect():
                return {}
        
        try:
            request = {'pattern': 'user>>>'}
            response = await self.stub.QueryStats(request, timeout=5.0)
            return self._parse_stats_response(response)
        except grpc.RpcError as e:
            print(f"⚠️  gRPC error: {e.code()}", file=sys.stderr)
            self._connected = False
            return {}
        except Exception as e:
            print(f"⚠️  Query error: {e}", file=sys.stderr)
            return {}
    
    def _parse_stats_response(self, response: dict) -> Dict[str, Dict[str, int]]:
        result = defaultdict(lambda: {'uplink': 0, 'downlink': 0})
        
        for stat in response.get('stat', []):
            name = stat.get('name', '')
            value = stat.get('value', 0)
            parts = name.split('>>>')
            if len(parts) == 4 and parts[0] == 'user' and parts[2] == 'traffic':
                email = parts[1]
                direction = parts[3]
                if direction in ('uplink', 'downlink'):
                    result[email][direction] = int(value)
        
        return dict(result)

# ============================================================================
# TRAFFIC AGGREGATOR
# ============================================================================

class TrafficAggregator:
    def __init__(self):
        self.users: Dict[str, TrafficData] = {}
        self._previous: Dict[str, Dict[str, int]] = {}
    
    def update(self, stats: Dict[str, Dict[str, int]], interval: float) -> Dict[str, TrafficData]:
        current_time = time.time()
        
        for email, counters in stats.items():
            uplink = counters['uplink']
            downlink = counters['downlink']
            
            if email not in self.users:
                self.users[email] = TrafficData(
                    uplink=uplink,
                    downlink=downlink,
                    last_update=current_time
                )
                self._previous[email] = {'uplink': uplink, 'downlink': downlink}
                continue
            
            prev = self._previous[email]
            delta_uplink = uplink - prev['uplink'] if uplink >= prev['uplink'] else uplink
            delta_downlink = downlink - prev['downlink'] if downlink >= prev['downlink'] else downlink
            
            uplink_speed = delta_uplink / interval if interval > 0 else 0
            downlink_speed = delta_downlink / interval if interval > 0 else 0
            
            self.users[email].uplink = uplink
            self.users[email].downlink = downlink
            self.users[email].uplink_speed = uplink_speed
            self.users[email].downlink_speed = downlink_speed
            self.users[email].last_update = current_time
            
            self._previous[email] = {'uplink': uplink, 'downlink': downlink}
        
        current_emails = set(stats.keys())
        removed_emails = set(self.users.keys()) - current_emails
        for email in removed_emails:
            del self.users[email]
            if email in self._previous:
                del self._previous[email]
        
        return self.users
    
    def get_totals(self) -> Tuple[int, int, float, float]:
        total_uplink = sum(u.uplink for u in self.users.values())
        total_downlink = sum(u.downlink for u in self.users.values())
        total_up_speed = sum(u.uplink_speed for u in self.users.values())
        total_down_speed = sum(u.downlink_speed for u in self.users.values())
        return total_uplink, total_downlink, total_up_speed, total_down_speed

# ============================================================================
# BASEROW SYNC
# ============================================================================

class BaserowSync:
    def __init__(self, token: str, table_id: str, server_name: str, min_sync_mb: float = 10.0, enabled: bool = True):
        self.token = token
        self.table_id = table_id
        self.server_name = server_name
        self.min_sync_mb = min_sync_mb * 1024 * 1024
        self.enabled = enabled
        
        self.base_url = "https://api.baserow.io/api/database/rows/table"
        self.headers = {
            "Authorization": f"Token {token}",
            "Content-Type": "application/json"
        }
        
        self._last_synced: Dict[str, int] = {}
        self._last_sync_time = time.time()
        
        if enabled:
            print(f"🔄 Baserow Sync: Enabled")
            print(f"   Server: {server_name}, Min: {min_sync_mb:.0f} MB")
    
    def should_sync(self, email: str, total: int) -> bool:
        if not self.enabled or total < self.min_sync_mb:
            return False
        
        last_total = self._last_synced.get(email, 0)
        delta = total - last_total
        return delta >= self.min_sync_mb
    
    def sync_user(self, email: str, uplink: int, downlink: int) -> bool:
        total = uplink + downlink
        
        if not self.should_sync(email, total):
            return False
        
        try:
            user_row = self._find_user(email)
            if not user_row:
                return False
            
            row_id = user_row['id']
            gb_total = total / (1024 ** 3)
            
            update_data = {self.server_name: round(gb_total, 2)}
            
            if self._update_row(row_id, update_data):
                self._last_synced[email] = total
                print(f"✅ Synced {email}: {gb_total:.2f} GB")
                return True
        except Exception as e:
            print(f"❌ Sync error {email}: {e}")
        
        return False
    
    def _find_user(self, email: str) -> Optional[Dict]:
        try:
            url = f"{self.base_url}/{self.table_id}/"
            params = {"user_field_names": "true", "search": email}
            response = requests.get(url, headers=self.headers, params=params, timeout=10)
            
            if response.status_code == 200:
                results = response.json().get('results', [])
                for row in results:
                    if row.get('user') == email:
                        return row
        except Exception as e:
            print(f"⚠️  Find error {email}: {e}")
        return None
    
    def _update_row(self, row_id: int, data: Dict) -> bool:
        try:
            url = f"{self.base_url}/{self.table_id}/{row_id}/"
            params = {"user_field_names": "true"}
            response = requests.patch(url, headers=self.headers, params=params, json=data, timeout=10)
            return response.status_code == 200
        except Exception as e:
            print(f"⚠️  Update error: {e}")
            return False
    
    def sync_all(self, users: Dict[str, TrafficData], sync_interval_minutes: int) -> int:
        if not self.enabled:
            return 0
        
        current_time = time.time()
        time_since_sync = (current_time - self._last_sync_time) / 60
        
        if time_since_sync < sync_interval_minutes:
            return 0
        
        self._last_sync_time = current_time
        synced_count = 0
        
        for email, data in users.items():
            if self.sync_user(email, data.uplink, data.downlink):
                synced_count += 1
        
        if synced_count > 0:
            print(f"📊 Synced {synced_count} users to Baserow")
        
        return synced_count

# ============================================================================
# CONSOLE RENDERER
# ============================================================================

class ConsoleRenderer:
    GREEN = '\033[0;32m'
    CYAN = '\033[0;36m'
    YELLOW = '\033[1;33m'
    WHITE = '\033[1;37m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'
    
    @staticmethod
    def clear_screen():
        print('\033[2J\033[H', end='')
    
    @staticmethod
    def format_bytes(bytes_val: int) -> str:
        if bytes_val >= 1073741824:
            return f"{bytes_val / 1073741824:.2f} GB"
        elif bytes_val >= 1048576:
            return f"{bytes_val / 1048576:.2f} MB"
        elif bytes_val >= 1024:
            return f"{bytes_val / 1024:.2f} KB"
        else:
            return f"{bytes_val} B"
    
    @staticmethod
    def format_speed(bytes_per_sec: float) -> str:
        if bytes_per_sec >= 1048576:
            return f"{bytes_per_sec / 1048576:.2f} MB/s"
        elif bytes_per_sec >= 1024:
            return f"{bytes_per_sec / 1024:.2f} KB/s"
        else:
            return f"{bytes_per_sec:.0f} B/s"
    
    def render(self, users: Dict[str, TrafficData], aggregator: TrafficAggregator):
        self.clear_screen()
        
        print(f"{self.BLUE}╔{'═' * 120}╗{self.NC}")
        print(f"{self.BLUE}║{' ' * 35}XRAY TRAFFIC MONITOR - Python HPC Edition{' ' * 42}║{self.NC}")
        print(f"{self.BLUE}╚{'═' * 120}╝{self.NC}")
        print()
        
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        active_count = sum(1 for u in users.values() if u.uplink_speed > 0 or u.downlink_speed > 0)
        print(f"{self.YELLOW}Время:{self.NC} {timestamp}    "
              f"{self.YELLOW}Всего:{self.NC} {len(users)}    "
              f"{self.YELLOW}Активных:{self.NC} {active_count}")
        print()
        
        header = f"{self.CYAN}{'EMAIL':<30} {'UPLINK':>15} {'DOWNLINK':>15} {'UP SPEED':>15} {'DOWN SPEED':>15} {'TOTAL':>15}{self.NC}"
        print(header)
        print("─" * 120)
        
        sorted_users = sorted(users.items(), key=lambda x: (x[1].uplink_speed + x[1].downlink_speed, x[0]), reverse=True)
        
        for email, data in sorted_users:
            is_active = data.uplink_speed > 0 or data.downlink_speed > 0
            color = self.GREEN if is_active else self.NC
            
            line = (f"{color}{email:<30} "
                   f"{self.format_bytes(data.uplink):>15} "
                   f"{self.format_bytes(data.downlink):>15} "
                   f"{self.format_speed(data.uplink_speed):>15} "
                   f"{self.format_speed(data.downlink_speed):>15} "
                   f"{self.format_bytes(data.total):>15}{self.NC}")
            print(line)
        
        total_up, total_down, total_up_speed, total_down_speed = aggregator.get_totals()
        print("─" * 120)
        total_line = (f"{self.WHITE}{'ИТОГО:':<30} "
                     f"{self.format_bytes(total_up):>15} "
                     f"{self.format_bytes(total_down):>15} "
                     f"{self.format_speed(total_up_speed):>15} "
                     f"{self.format_speed(total_down_speed):>15} "
                     f"{self.format_bytes(total_up + total_down):>15}{self.NC}")
        print(total_line)
        print()
        print(f"{self.YELLOW}Легенда:{self.NC} {self.GREEN}Зеленый{self.NC} = активен | {self.WHITE}Белый{self.NC} = неактивен")

# ============================================================================
# CONFIG LOADER
# ============================================================================

def load_config(config_path: str = "/opt/xray-monitor/monitor_config.conf") -> Dict:
    config = {
        'baserow_token': None,
        'baserow_table_id': None,
        'baserow_enabled': False,
        'server_name': 'Unknown',
        'min_sync_mb': 10.0,
        'sync_interval': 5,
    }
    
    if not os.path.exists(config_path):
        return config
    
    try:
        with open(config_path, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                
                if '=' in line:
                    key, value = line.split('=', 1)
                    key = key.strip()
                    value = value.split('#')[0].strip()
                    
                    if key == 'BASEROW_TOKEN':
                        config['baserow_token'] = value
                    elif key == 'BASEROW_TABLE_ID':
                        config['baserow_table_id'] = value
                    elif key == 'BASEROW_ENABLED':
                        config['baserow_enabled'] = value.lower() == 'true'
                    elif key == 'SERVER_NAME':
                        config['server_name'] = value
                    elif key == 'MIN_SYNC_MB':
                        config['min_sync_mb'] = float(value)
                    elif key == 'SYNC_INTERVAL':
                        config['sync_interval'] = int(value)
    except Exception as e:
        print(f"⚠️  Config error: {e}")
    
    return config

# ============================================================================
# MAIN
# ============================================================================

async def monitoring_loop(client, aggregator, renderer, baserow, interval, sync_interval):
    print(f"🚀 Запуск мониторинга (интервал: {interval}s)...")
    
    if not await client.connect():
        print("❌ Не удалось подключиться к Xray API", file=sys.stderr)
        return
    
    print("✅ Подключено к Xray Stats API")
    
    try:
        while True:
            loop_start = time.time()
            
            stats = await client.query_all_stats()
            
            if stats:
                users = aggregator.update(stats, interval)
                
                if renderer:
                    renderer.render(users, aggregator)
                
                if baserow:
                    baserow.sync_all(users, sync_interval)
            
            elapsed = time.time() - loop_start
            sleep_time = max(0, interval - elapsed)
            await asyncio.sleep(sleep_time)
    
    except KeyboardInterrupt:
        print("\n⏹️  Остановка...")
    finally:
        await client.disconnect()

def main():
    parser = argparse.ArgumentParser(description='Xray Traffic Monitor')
    parser.add_argument('--mode', choices=['console', 'prometheus', 'both'], default='console')
    parser.add_argument('--interval', type=float, default=2.0)
    parser.add_argument('--server', type=str, default='127.0.0.1:10085')
    parser.add_argument('--port', type=int, default=9090)
    args = parser.parse_args()
    
    config = load_config()
    
    client = XrayStatsClient(server=args.server)
    aggregator = TrafficAggregator()
    renderer = ConsoleRenderer() if args.mode in ('console', 'both') else None
    
    baserow = None
    if config['baserow_enabled'] and config['baserow_token'] and config['baserow_table_id']:
        baserow = BaserowSync(
            token=config['baserow_token'],
            table_id=config['baserow_table_id'],
            server_name=config['server_name'],
            min_sync_mb=config['min_sync_mb'],
            enabled=True
        )
    
    try:
        asyncio.run(monitoring_loop(
            client, aggregator, renderer, baserow,
            args.interval, config['sync_interval']
        ))
    except KeyboardInterrupt:
        print("\n✅ Завершено")

if __name__ == '__main__':
    main()
