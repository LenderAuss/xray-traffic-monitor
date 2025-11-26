#!/usr/bin/env python3
"""
Xray Traffic Monitor - High-Performance Python Implementation with Baserow
===========================================================================
Version: 4.2 - Fixed traffic accumulation logic
"""

import asyncio
import time
import argparse
import sys
import os
import json
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
        while pos < len(data):
            byte = data[pos]
            pos += 1
            bytes_read += 1
            result |= (byte & 0x7f) << shift
            if (byte & 0x80) == 0:
                break
            shift += 7
        return result, bytes_read
    
    @staticmethod
    def _skip_field(data: bytes, pos: int, wire_type: int) -> int:
        if wire_type == 0:
            while pos < len(data) and (data[pos] & 0x80):
                pos += 1
            return pos + 1
        elif wire_type == 2:
            length, bytes_read = StatsServiceStub._read_varint(data, pos)
            return pos + bytes_read + length
        elif wire_type == 5:
            return pos + 4
        elif wire_type == 1:
            return pos + 8
        return pos
    
    @staticmethod
    def _parse_stat(data: bytes) -> Optional[dict]:
        pos = 0
        name = None
        value = 0
        
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
                name = data[pos:pos + length].decode('utf-8')
                pos += length
            elif field_number == 2 and wire_type == 0:
                value, bytes_read = StatsServiceStub._read_varint(data, pos)
                pos += bytes_read
            else:
                pos = StatsServiceStub._skip_field(data, pos, wire_type)
        
        if name:
            return {'name': name, 'value': value}
        return None


# ============================================================================
# XRAY STATS CLIENT
# ============================================================================

class XrayStatsClient:
    def __init__(self, server: str = "127.0.0.1:10085"):
        self.server = server
        self.channel = None
        self.stub = None
    
    async def connect(self) -> bool:
        try:
            self.channel = grpc_aio.insecure_channel(self.server)
            self.stub = StatsServiceStub(self.channel)
            return True
        except Exception as e:
            print(f"❌ Connection error: {e}")
            return False
    
    async def disconnect(self):
        if self.channel:
            await self.channel.close()
    
    async def query_all_stats(self) -> Dict[str, Tuple[int, int]]:
        if not self.stub:
            return {}
        
        try:
            response = await self.stub.QueryStats({'pattern': 'user>>>'})
            stats = response.get('stat', [])
            
            users = {}
            for stat in stats:
                name = stat.get('name', '')
                value = stat.get('value', 0)
                
                if '>>>traffic>>>' in name:
                    parts = name.split('>>>')
                    if len(parts) >= 4:
                        email = parts[1]
                        direction = parts[3]
                        
                        if email not in users:
                            users[email] = [0, 0]
                        
                        if direction == 'uplink':
                            users[email][0] = value
                        elif direction == 'downlink':
                            users[email][1] = value
            
            return {k: tuple(v) for k, v in users.items()}
        except Exception as e:
            print(f"⚠️  Query error: {e}")
            return {}


# ============================================================================
# TRAFFIC DATA
# ============================================================================

@dataclass
class TrafficData:
    uplink: int = 0
    downlink: int = 0
    up_speed: float = 0.0
    down_speed: float = 0.0
    last_uplink: int = 0
    last_downlink: int = 0


class TrafficAggregator:
    def __init__(self):
        self.users: Dict[str, TrafficData] = {}
        self.total_up: int = 0
        self.total_down: int = 0
    
    def update(self, stats: Dict[str, Tuple[int, int]], interval: float) -> Dict[str, TrafficData]:
        for email, (uplink, downlink) in stats.items():
            if email not in self.users:
                self.users[email] = TrafficData()
            
            data = self.users[email]
            
            # Calculate speeds
            up_diff = uplink - data.last_uplink if uplink >= data.last_uplink else uplink
            down_diff = downlink - data.last_downlink if downlink >= data.last_downlink else downlink
            
            data.up_speed = up_diff / interval if interval > 0 else 0
            data.down_speed = down_diff / interval if interval > 0 else 0
            
            data.uplink = uplink
            data.downlink = downlink
            data.last_uplink = uplink
            data.last_downlink = downlink
        
        self.total_up = sum(d.uplink for d in self.users.values())
        self.total_down = sum(d.downlink for d in self.users.values())
        
        return self.users


# ============================================================================
# BASEROW SYNC - FIXED LOGIC
# ============================================================================

class BaserowSync:
    """Синхронизация с Baserow - ИСПРАВЛЕННАЯ ЛОГИКА"""
    
    STATE_FILE = "/opt/xray-monitor/sync_state.json"
    
    def __init__(self, token: str, table_id: str, server_name: str, min_sync_mb: float = 10.0, enabled: bool = True):
        self.token = token
        self.table_id = table_id
        self.server_name = server_name
        self.min_sync_bytes = int(min_sync_mb * 1024 * 1024)
        self.enabled = enabled
        
        self.base_url = "https://api.baserow.io/api/database/rows/table"
        self.headers = {
            "Authorization": f"Token {token}",
            "Content-Type": "application/json"
        }
        
        # Загружаем состояние из файла (переживает перезапуск мониторинга)
        self._last_synced: Dict[str, int] = {}
        self._baseline: Dict[str, int] = {}  # Начальные значения при старте
        self._baseline_initialized = False
        self._last_sync_time = time.time()
        
        self._load_state()
        
        if enabled:
            print(f"🔄 Baserow Sync: Enabled")
            print(f"   Server: {server_name}, Min: {min_sync_mb:.0f} MB")
    
    def _load_state(self):
        """Загружает состояние из файла"""
        try:
            if os.path.exists(self.STATE_FILE):
                with open(self.STATE_FILE, 'r') as f:
                    state = json.load(f)
                    self._last_synced = state.get('last_synced', {})
                    print(f"📂 Loaded sync state for {len(self._last_synced)} users")
        except Exception as e:
            print(f"⚠️  Could not load state: {e}")
    
    def _save_state(self):
        """Сохраняет состояние в файл"""
        try:
            state = {
                'last_synced': self._last_synced,
                'timestamp': datetime.now().isoformat()
            }
            with open(self.STATE_FILE, 'w') as f:
                json.dump(state, f)
        except Exception as e:
            print(f"⚠️  Could not save state: {e}")
    
    def extract_username(self, email: str) -> str:
        """Извлекает username (до первого _)"""
        if '_' in email:
            return email.split('_')[0]
        return email
    
    def _initialize_baseline(self, users: Dict[str, TrafficData]):
        """Инициализирует baseline при первом запуске"""
        if self._baseline_initialized:
            return
        
        for email, data in users.items():
            total = data.uplink + data.downlink
            # Если у нас нет сохранённого состояния для этого пользователя,
            # используем текущее значение как baseline (не прибавляем его)
            if email not in self._last_synced:
                self._baseline[email] = total
                self._last_synced[email] = total
        
        self._baseline_initialized = True
        self._save_state()
        print(f"📊 Baseline initialized for {len(self._baseline)} users")
    
    def _calculate_delta(self, email: str, current_total: int) -> int:
        """Вычисляет дельту трафика для синхронизации"""
        last_synced = self._last_synced.get(email, 0)
        
        # Если current_total < last_synced - значит Xray был перезапущен
        # В этом случае весь current_total это новый трафик
        if current_total < last_synced:
            print(f"🔄 Xray restart detected for {email}, resetting baseline")
            return current_total
        
        return current_total - last_synced
    
    def should_sync(self, email: str, total: int) -> bool:
        """Проверяет нужна ли синхронизация"""
        if not self.enabled:
            return False
        
        delta = self._calculate_delta(email, total)
        return delta >= self.min_sync_bytes
    
    def get_user_gb_from_baserow(self, email: str) -> float:
        """Получает текущий GB из Baserow"""
        try:
            username = self.extract_username(email)
            url = f"{self.base_url}/{self.table_id}/"
            params = {"user_field_names": "true"}
            
            response = requests.get(url, headers=self.headers, params=params, timeout=10)
            
            if response.status_code == 200:
                results = response.json().get('results', [])
                for row in results:
                    if row.get('user') == username and row.get('server') == self.server_name:
                        gb_value = row.get('GB', 0)
                        if isinstance(gb_value, str):
                            gb_value = ''.join(c for c in gb_value if c.isdigit() or c == '.')
                            try:
                                gb_value = float(gb_value) if gb_value else 0.0
                            except:
                                gb_value = 0.0
                        return float(gb_value or 0)
        except Exception as e:
            print(f"⚠️  Error getting GB: {e}")
        return 0.0
    
    def _find_user_row(self, username: str) -> Optional[Dict]:
        """Ищет строку по user И server"""
        try:
            url = f"{self.base_url}/{self.table_id}/"
            params = {"user_field_names": "true"}
            
            response = requests.get(url, headers=self.headers, params=params, timeout=10)
            
            if response.status_code == 200:
                results = response.json().get('results', [])
                for row in results:
                    if row.get('user') == username and row.get('server') == self.server_name:
                        return row
        except Exception as e:
            print(f"⚠️  Find error: {e}")
        return None
    
    def _create_row(self, data: Dict) -> bool:
        """Создает строку"""
        try:
            url = f"{self.base_url}/{self.table_id}/"
            params = {"user_field_names": "true"}
            response = requests.post(url, headers=self.headers, params=params, json=data, timeout=10)
            return response.status_code in (200, 201)
        except Exception as e:
            print(f"⚠️  Create error: {e}")
            return False
    
    def _update_row(self, row_id: int, data: Dict) -> bool:
        """Обновляет строку"""
        try:
            url = f"{self.base_url}/{self.table_id}/{row_id}/"
            params = {"user_field_names": "true"}
            response = requests.patch(url, headers=self.headers, params=params, json=data, timeout=10)
            return response.status_code == 200
        except Exception as e:
            print(f"⚠️  Update error: {e}")
            return False
    
    def sync_user(self, email: str, uplink: int, downlink: int) -> bool:
        """Синхронизирует пользователя - ИСПРАВЛЕННАЯ ЛОГИКА"""
        total = uplink + downlink
        
        if not self.should_sync(email, total):
            return False
        
        try:
            username = self.extract_username(email)
            
            # Вычисляем дельту (только новый трафик!)
            delta = self._calculate_delta(email, total)
            
            if delta <= 0:
                return False
            
            # Получаем текущий GB из Baserow
            current_gb = self.get_user_gb_from_baserow(email)
            current_bytes = int(current_gb * 1024 ** 3)
            
            # Прибавляем ТОЛЬКО дельту
            new_total_bytes = current_bytes + delta
            new_total_gb = round(new_total_bytes / (1024 ** 3), 6)
            
            # Ищем строку
            user_row = self._find_user_row(username)
            
            if user_row:
                # Обновляем
                row_id = user_row['id']
                update_data = {"GB": new_total_gb}
                
                if self._update_row(row_id, update_data):
                    self._last_synced[email] = total  # Запоминаем текущий total
                    self._save_state()
                    delta_gb = delta / (1024 ** 3)
                    print(f"✅ Synced {username}: +{delta_gb:.4f} GB → {new_total_gb:.4f} GB total")
                    return True
            else:
                # Создаем новую запись
                create_data = {
                    "user": username,
                    "server": self.server_name,
                    "GB": round(delta / (1024 ** 3), 6)  # Только дельта для новой записи
                }
                
                if self._create_row(create_data):
                    self._last_synced[email] = total
                    self._save_state()
                    print(f"✅ Created {username}: {delta / (1024 ** 3):.4f} GB")
                    return True
                    
        except Exception as e:
            print(f"❌ Sync error {email}: {e}")
        
        return False
    
    def sync_all(self, users: Dict[str, TrafficData], sync_interval_minutes: int) -> int:
        """Синхронизирует всех по расписанию"""
        if not self.enabled:
            return 0
        
        # Инициализируем baseline при первом вызове
        self._initialize_baseline(users)
        
        current_time = time.time()
        time_since_sync = (current_time - self._last_sync_time) / 60
        
        if time_since_sync < sync_interval_minutes:
            return 0
        
        self._last_sync_time = current_time
        synced_count = 0
        
        print(f"\n{'='*60}")
        print(f"📊 Автосинхронизация с Baserow")
        print(f"{'='*60}")
        
        for email, data in users.items():
            if self.sync_user(email, data.uplink, data.downlink):
                synced_count += 1
        
        if synced_count > 0:
            print(f"{'='*60}")
            print(f"✅ Синхронизировано: {synced_count}")
            print(f"{'='*60}\n")
        else:
            print(f"ℹ️  Нет данных для синхронизации (дельта < {self.min_sync_bytes / (1024*1024):.0f} MB)")
            print(f"{'='*60}\n")
        
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
        active_count = sum(1 for d in users.values() if d.up_speed > 0 or d.down_speed > 0)
        
        print(f"Время: {timestamp}    Всего: {len(users)}    Активных: {active_count}")
        
        # Header
        print(f"{'EMAIL':<20} {'UPLINK':>15} {'DOWNLINK':>15} {'UP SPEED':>15} {'DOWN SPEED':>15} {'TOTAL':>15}")
        print("-" * 95)
        
        # Users
        for email, data in sorted(users.items()):
            total = data.uplink + data.downlink
            is_active = data.up_speed > 0 or data.down_speed > 0
            color = self.GREEN if is_active else self.NC
            
            print(f"{color}{email:<20} "
                  f"{self.format_bytes(data.uplink):>15} "
                  f"{self.format_bytes(data.downlink):>15} "
                  f"{self.format_speed(data.up_speed):>15} "
                  f"{self.format_speed(data.down_speed):>15} "
                  f"{self.format_bytes(total):>15}{self.NC}")
        
        # Total
        print("-" * 95)
        total_all = aggregator.total_up + aggregator.total_down
        print(f"{'ИТОГО:':<20} "
              f"{self.format_bytes(aggregator.total_up):>15} "
              f"{self.format_bytes(aggregator.total_down):>15} "
              f"{'':>15} {'':>15} "
              f"{self.format_bytes(total_all):>15}")
        
        print()
        print(f"Легенда: {self.GREEN}Зеленый{self.NC} = активен | Белый = неактивен")


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
        if baserow:
            baserow._save_state()
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
