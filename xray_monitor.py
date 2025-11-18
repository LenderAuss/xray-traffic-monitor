#!/usr/bin/env python3
"""
Xray Traffic Monitor - High-Performance Python Implementation
==============================================================

Архитектура:
- XrayStatsClient: gRPC клиент с постоянным соединением
- TrafficAggregator: хранение состояния и расчет скоростей
- ConsoleRenderer: вывод таблицы в терминал
- PrometheusExporter: HTTP сервер для метрик
- main(): координация компонентов

Использование:
    python3 xray_monitor.py --mode console --interval 5
    python3 xray_monitor.py --mode prometheus --port 9090
    python3 xray_monitor.py --mode both --interval 5 --port 9090
"""

import asyncio
import time
import argparse
import sys
from typing import Dict, Tuple, Optional
from dataclasses import dataclass, field
from collections import defaultdict
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread

# gRPC imports
import grpc
from grpc import aio as grpc_aio

# ============================================================================
# PROTOBUF DEFINITIONS (встроенные, без отдельных .proto файлов)
# ============================================================================
# Вместо компиляции .proto файлов, используем dynamic stubs

class StatsServiceStub:
    """Обертка для gRPC StatsService"""
    def __init__(self, channel):
        self.channel = channel
        # Метод QueryStats
        self.QueryStats = channel.unary_unary(
            '/v2ray.core.app.stats.command.StatsService/QueryStats',
            request_serializer=self._serialize_query_request,
            response_deserializer=self._deserialize_query_response,
        )
    
    @staticmethod
    def _serialize_query_request(request: dict) -> bytes:
        """Сериализация QueryStatsRequest в protobuf"""
        # Простейшая protobuf сериализация для pattern (field 1, type string)
        pattern = request.get('pattern', '')
        if not pattern:
            return b''
        # Protobuf wire format: field_number << 3 | wire_type
        # String: wire_type = 2, field 1: tag = (1 << 3) | 2 = 0x0a
        pattern_bytes = pattern.encode('utf-8')
        length = len(pattern_bytes)
        # Varint encoding для длины
        length_varint = []
        while length > 127:
            length_varint.append((length & 0x7f) | 0x80)
            length >>= 7
        length_varint.append(length & 0x7f)
        return bytes([0x0a] + length_varint) + pattern_bytes
    
    @staticmethod
    def _deserialize_query_response(response_bytes: bytes) -> dict:
        """Десериализация QueryStatsResponse из protobuf"""
        stats = []
        pos = 0
        
        while pos < len(response_bytes):
            # Читаем tag (field_number << 3 | wire_type)
            if pos >= len(response_bytes):
                break
            tag = response_bytes[pos]
            pos += 1
            
            field_number = tag >> 3
            wire_type = tag & 0x07
            
            if field_number == 1 and wire_type == 2:  # stat field (repeated message)
                # Читаем длину
                length, bytes_read = StatsServiceStub._read_varint(response_bytes, pos)
                pos += bytes_read
                
                # Читаем stat message
                stat_data = response_bytes[pos:pos + length]
                pos += length
                
                stat = StatsServiceStub._parse_stat(stat_data)
                if stat:
                    stats.append(stat)
            else:
                # Пропускаем неизвестные поля
                pos = StatsServiceStub._skip_field(response_bytes, pos, wire_type)
        
        return {'stat': stats}
    
    @staticmethod
    def _read_varint(data: bytes, pos: int) -> Tuple[int, int]:
        """Читает varint, возвращает (значение, количество байт)"""
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
        """Парсит Stat message"""
        stat = {}
        pos = 0
        
        while pos < len(data):
            if pos >= len(data):
                break
            tag = data[pos]
            pos += 1
            
            field_number = tag >> 3
            wire_type = tag & 0x07
            
            if field_number == 1 and wire_type == 2:  # name (string)
                length, bytes_read = StatsServiceStub._read_varint(data, pos)
                pos += bytes_read
                stat['name'] = data[pos:pos + length].decode('utf-8', errors='ignore')
                pos += length
            elif field_number == 2 and wire_type == 0:  # value (int64)
                value, bytes_read = StatsServiceStub._read_varint(data, pos)
                pos += bytes_read
                stat['value'] = value
            else:
                pos = StatsServiceStub._skip_field(data, pos, wire_type)
        
        return stat if 'name' in stat else None
    
    @staticmethod
    def _skip_field(data: bytes, pos: int, wire_type: int) -> int:
        """Пропускает поле неизвестного типа"""
        if wire_type == 0:  # Varint
            while pos < len(data) and (data[pos] & 0x80):
                pos += 1
            return pos + 1
        elif wire_type == 2:  # Length-delimited
            length, bytes_read = StatsServiceStub._read_varint(data, pos)
            return pos + bytes_read + length
        else:
            return pos


# ============================================================================
# DATA STRUCTURES
# ============================================================================

@dataclass
class TrafficData:
    """Данные о трафике пользователя"""
    uplink: int = 0          # Текущий uplink (байты)
    downlink: int = 0        # Текущий downlink (байты)
    uplink_speed: float = 0.0    # Скорость upload (байт/сек)
    downlink_speed: float = 0.0  # Скорость download (байт/сек)
    last_update: float = field(default_factory=time.time)
    
    @property
    def total(self) -> int:
        """Общий трафик"""
        return self.uplink + self.downlink


# ============================================================================
# XRAY GRPC CLIENT
# ============================================================================

class XrayStatsClient:
    """
    gRPC клиент для Xray Stats API.
    
    Особенности:
    - Постоянное соединение
    - Автоматический reconnect при ошибках
    - Один запрос QueryStats на все данные
    """
    
    def __init__(self, server: str = "127.0.0.1:10085"):
        self.server = server
        self.channel: Optional[grpc_aio.Channel] = None
        self.stub: Optional[StatsServiceStub] = None
        self._connected = False
    
    async def connect(self) -> bool:
        """Устанавливает gRPC соединение"""
        try:
            self.channel = grpc_aio.insecure_channel(self.server)
            self.stub = StatsServiceStub(self.channel)
            
            # Проверка соединения
            await self.channel.channel_ready()
            self._connected = True
            return True
        except Exception as e:
            print(f"❌ Ошибка подключения к Xray API: {e}", file=sys.stderr)
            self._connected = False
            return False
    
    async def disconnect(self):
        """Закрывает соединение"""
        if self.channel:
            await self.channel.close()
            self._connected = False
    
    async def query_all_stats(self) -> Dict[str, Dict[str, int]]:
        """
        Запрашивает статистику ВСЕХ пользователей одним запросом.
        
        Returns:
            Dict[email, Dict[direction, bytes]]
            Пример: {
                'user@example.com': {'uplink': 12345, 'downlink': 67890},
                'user2@example.com': {'uplink': 111, 'downlink': 222}
            }
        """
        if not self._connected:
            if not await self.connect():
                return {}
        
        try:
            # Один запрос для всех пользователей
            request = {'pattern': 'user>>>'}
            response = await self.stub.QueryStats(request, timeout=5.0)
            
            # Парсим результат
            return self._parse_stats_response(response)
            
        except grpc.RpcError as e:
            print(f"⚠️  gRPC ошибка: {e.code()}", file=sys.stderr)
            self._connected = False
            return {}
        except Exception as e:
            print(f"⚠️  Ошибка запроса: {e}", file=sys.stderr)
            return {}
    
    def _parse_stats_response(self, response: dict) -> Dict[str, Dict[str, int]]:
        """
        Парсит ответ от QueryStats.
        
        Формат имени: user>>>email@example.com>>>traffic>>>uplink
        """
        result = defaultdict(lambda: {'uplink': 0, 'downlink': 0})
        
        for stat in response.get('stat', []):
            name = stat.get('name', '')
            value = stat.get('value', 0)
            
            # Парсим имя: user>>>EMAIL>>>traffic>>>DIRECTION
            parts = name.split('>>>')
            if len(parts) == 4 and parts[0] == 'user' and parts[2] == 'traffic':
                email = parts[1]
                direction = parts[3]  # uplink или downlink
                
                if direction in ('uplink', 'downlink'):
                    result[email][direction] = int(value)
        
        return dict(result)


# ============================================================================
# TRAFFIC AGGREGATOR
# ============================================================================

class TrafficAggregator:
    """
    Хранит состояние и вычисляет скорости.
    
    Логика:
    - Кэширует предыдущие значения счетчиков
    - Вычисляет дельту и скорость
    - Обрабатывает сброс счетчиков (если new < old)
    """
    
    def __init__(self):
        self.users: Dict[str, TrafficData] = {}
        self._previous: Dict[str, Dict[str, int]] = {}
    
    def update(self, stats: Dict[str, Dict[str, int]], interval: float) -> Dict[str, TrafficData]:
        """
        Обновляет статистику на основе новых данных.
        
        Args:
            stats: Новые значения счетчиков от Xray
            interval: Интервал между обновлениями (секунды)
        
        Returns:
            Обновленный словарь TrafficData
        """
        current_time = time.time()
        
        for email, counters in stats.items():
            uplink = counters['uplink']
            downlink = counters['downlink']
            
            # Инициализация нового пользователя
            if email not in self.users:
                self.users[email] = TrafficData(
                    uplink=uplink,
                    downlink=downlink,
                    last_update=current_time
                )
                self._previous[email] = {'uplink': uplink, 'downlink': downlink}
                continue
            
            # Получаем предыдущие значения
            prev = self._previous[email]
            prev_uplink = prev['uplink']
            prev_downlink = prev['downlink']
            
            # Вычисляем дельту (обработка сброса счетчиков)
            delta_uplink = uplink - prev_uplink if uplink >= prev_uplink else uplink
            delta_downlink = downlink - prev_downlink if downlink >= prev_downlink else downlink
            
            # Вычисляем скорость (байт/сек)
            uplink_speed = delta_uplink / interval if interval > 0 else 0
            downlink_speed = delta_downlink / interval if interval > 0 else 0
            
            # Обновляем данные пользователя
            self.users[email].uplink = uplink
            self.users[email].downlink = downlink
            self.users[email].uplink_speed = uplink_speed
            self.users[email].downlink_speed = downlink_speed
            self.users[email].last_update = current_time
            
            # Сохраняем текущие значения для следующей итерации
            self._previous[email] = {'uplink': uplink, 'downlink': downlink}
        
        # Удаляем пользователей, которых нет в новых данных
        current_emails = set(stats.keys())
        removed_emails = set(self.users.keys()) - current_emails
        for email in removed_emails:
            del self.users[email]
            if email in self._previous:
                del self._previous[email]
        
        return self.users
    
    def get_totals(self) -> Tuple[int, int, float, float]:
        """
        Возвращает суммарные значения.
        
        Returns:
            (total_uplink, total_downlink, total_up_speed, total_down_speed)
        """
        total_uplink = sum(u.uplink for u in self.users.values())
        total_downlink = sum(u.downlink for u in self.users.values())
        total_up_speed = sum(u.uplink_speed for u in self.users.values())
        total_down_speed = sum(u.downlink_speed for u in self.users.values())
        
        return total_uplink, total_downlink, total_up_speed, total_down_speed


# ============================================================================
# CONSOLE RENDERER
# ============================================================================

class ConsoleRenderer:
    """
    Выводит данные в консоль в виде таблицы.
    
    Формат:
    - Зеленый цвет для активных пользователей (скорость > 0)
    - Белый для неактивных
    - Итоговая строка внизу
    """
    
    # ANSI цвета
    GREEN = '\033[0;32m'
    CYAN = '\033[0;36m'
    YELLOW = '\033[1;33m'
    WHITE = '\033[1;37m'
    BLUE = '\033[0;34m'
    NC = '\033[0m'  # No Color
    
    @staticmethod
    def clear_screen():
        """Очищает экран"""
        print('\033[2J\033[H', end='')
    
    @staticmethod
    def format_bytes(bytes_val: int) -> str:
        """Форматирует байты в человекочитаемый вид"""
        if bytes_val >= 1073741824:  # >= 1 GB
            return f"{bytes_val / 1073741824:.2f} GB"
        elif bytes_val >= 1048576:  # >= 1 MB
            return f"{bytes_val / 1048576:.2f} MB"
        elif bytes_val >= 1024:  # >= 1 KB
            return f"{bytes_val / 1024:.2f} KB"
        else:
            return f"{bytes_val} B"
    
    @staticmethod
    def format_speed(bytes_per_sec: float) -> str:
        """Форматирует скорость"""
        if bytes_per_sec >= 1048576:
            return f"{bytes_per_sec / 1048576:.2f} MB/s"
        elif bytes_per_sec >= 1024:
            return f"{bytes_per_sec / 1024:.2f} KB/s"
        else:
            return f"{bytes_per_sec:.0f} B/s"
    
    def render(self, users: Dict[str, TrafficData], aggregator: TrafficAggregator):
        """Отрисовывает таблицу в консоли"""
        self.clear_screen()
        
        # Заголовок
        print(f"{self.BLUE}╔{'═' * 120}╗{self.NC}")
        print(f"{self.BLUE}║{' ' * 35}XRAY TRAFFIC MONITOR - Python HPC Edition{' ' * 42}║{self.NC}")
        print(f"{self.BLUE}╚{'═' * 120}╝{self.NC}")
        print()
        
        # Информация о времени
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        active_count = sum(1 for u in users.values() if u.uplink_speed > 0 or u.downlink_speed > 0)
        print(f"{self.YELLOW}Время:{self.NC} {timestamp}    "
              f"{self.YELLOW}Всего:{self.NC} {len(users)}    "
              f"{self.YELLOW}Активных:{self.NC} {active_count}")
        print()
        
        # Заголовок таблицы
        header = f"{self.CYAN}{'EMAIL':<30} {'UPLINK':>15} {'DOWNLINK':>15} {'UP SPEED':>15} {'DOWN SPEED':>15} {'TOTAL':>15}{self.NC}"
        print(header)
        print("─" * 120)
        
        # Сортируем по активности (сначала активные)
        sorted_users = sorted(
            users.items(),
            key=lambda x: (x[1].uplink_speed + x[1].downlink_speed, x[0]),
            reverse=True
        )
        
        # Строки пользователей
        for email, data in sorted_users:
            # Цвет: зеленый если активен, иначе белый
            is_active = data.uplink_speed > 0 or data.downlink_speed > 0
            color = self.GREEN if is_active else self.NC
            
            line = (f"{color}{email:<30} "
                   f"{self.format_bytes(data.uplink):>15} "
                   f"{self.format_bytes(data.downlink):>15} "
                   f"{self.format_speed(data.uplink_speed):>15} "
                   f"{self.format_speed(data.downlink_speed):>15} "
                   f"{self.format_bytes(data.total):>15}{self.NC}")
            print(line)
        
        # Итоговая строка
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
        print(f"{self.YELLOW}Легенда:{self.NC} {self.GREEN}Зеленый{self.NC} = активен | "
              f"{self.WHITE}Белый{self.NC} = неактивен")


# ============================================================================
# PROMETHEUS EXPORTER
# ============================================================================

class PrometheusExporter:
    """
    HTTP сервер для экспорта метрик в формате Prometheus.
    
    Метрики:
    - xray_traffic_bytes_total{email="...", direction="uplink|downlink"}
    - xray_speed_bytes_per_second{email="...", direction="uplink|downlink"}
    """
    
    def __init__(self, port: int = 9090):
        self.port = port
        self.aggregator: Optional[TrafficAggregator] = None
        self.server: Optional[HTTPServer] = None
        self.thread: Optional[Thread] = None
    
    def start(self, aggregator: TrafficAggregator):
        """Запускает HTTP сервер в отдельном потоке"""
        self.aggregator = aggregator
        
        handler = self._create_handler()
        self.server = HTTPServer(('0.0.0.0', self.port), handler)
        
        self.thread = Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        
        print(f"✅ Prometheus exporter запущен на ::{self.port}/metrics")
    
    def stop(self):
        """Останавливает сервер"""
        if self.server:
            self.server.shutdown()
    
    def _create_handler(self):
        """Создает handler для HTTP запросов"""
        aggregator = self.aggregator
        
        class MetricsHandler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == '/metrics':
                    metrics = self._generate_metrics()
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/plain; charset=utf-8')
                    self.end_headers()
                    self.wfile.write(metrics.encode('utf-8'))
                else:
                    self.send_response(404)
                    self.end_headers()
            
            def _generate_metrics(self) -> str:
                """Генерирует метрики в формате Prometheus"""
                lines = []
                
                # HELP и TYPE для traffic_bytes_total
                lines.append('# HELP xray_traffic_bytes_total Total traffic in bytes')
                lines.append('# TYPE xray_traffic_bytes_total counter')
                
                for email, data in aggregator.users.items():
                    # Экранируем email для label
                    safe_email = email.replace('"', '\\"')
                    lines.append(f'xray_traffic_bytes_total{{email="{safe_email}",direction="uplink"}} {data.uplink}')
                    lines.append(f'xray_traffic_bytes_total{{email="{safe_email}",direction="downlink"}} {data.downlink}')
                
                lines.append('')
                
                # HELP и TYPE для speed
                lines.append('# HELP xray_speed_bytes_per_second Current traffic speed in bytes per second')
                lines.append('# TYPE xray_speed_bytes_per_second gauge')
                
                for email, data in aggregator.users.items():
                    safe_email = email.replace('"', '\\"')
                    lines.append(f'xray_speed_bytes_per_second{{email="{safe_email}",direction="uplink"}} {data.uplink_speed:.2f}')
                    lines.append(f'xray_speed_bytes_per_second{{email="{safe_email}",direction="downlink"}} {data.downlink_speed:.2f}')
                
                return '\n'.join(lines) + '\n'
            
            def log_message(self, format, *args):
                # Отключаем стандартное логирование запросов
                pass
        
        return MetricsHandler


# ============================================================================
# MAIN LOOP
# ============================================================================

async def monitoring_loop(
    client: XrayStatsClient,
    aggregator: TrafficAggregator,
    renderer: Optional[ConsoleRenderer],
    interval: float
):
    """
    Основной цикл мониторинга.
    
    Args:
        client: gRPC клиент
        aggregator: Агрегатор данных
        renderer: Рендерер (None если не нужен вывод в консоль)
        interval: Интервал опроса (секунды)
    """
    print(f"🚀 Запуск мониторинга (интервал: {interval}s)...")
    
    # Первое подключение
    if not await client.connect():
        print("❌ Не удалось подключиться к Xray API", file=sys.stderr)
        return
    
    print("✅ Подключено к Xray Stats API")
    
    try:
        while True:
            loop_start = time.time()
            
            # Получаем статистику одним запросом
            stats = await client.query_all_stats()
            
            if stats:
                # Обновляем агрегатор
                users = aggregator.update(stats, interval)
                
                # Выводим в консоль если нужно
                if renderer:
                    renderer.render(users, aggregator)
            
            # Ждем до следующей итерации
            elapsed = time.time() - loop_start
            sleep_time = max(0, interval - elapsed)
            await asyncio.sleep(sleep_time)
            
    except KeyboardInterrupt:
        print("\n⏹️  Остановка мониторинга...")
    finally:
        await client.disconnect()


# ============================================================================
# CLI INTERFACE
# ============================================================================

def main():
    parser = argparse.ArgumentParser(
        description='Xray Traffic Monitor - High-Performance Python Edition',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Примеры использования:
  %(prog)s --mode console --interval 5
  %(prog)s --mode prometheus --port 9090
  %(prog)s --mode both --interval 5 --port 9090
  %(prog)s --server 127.0.0.1:10086 --interval 3
        """
    )
    
    parser.add_argument(
        '--mode',
        choices=['console', 'prometheus', 'both'],
        default='console',
        help='Режим работы: console (вывод в терминал), prometheus (HTTP метрики), both (оба)'
    )
    
    parser.add_argument(
        '--interval',
        type=float,
        default=5.0,
        help='Интервал опроса Xray API (секунды, по умолчанию: 5)'
    )
    
    parser.add_argument(
        '--server',
        type=str,
        default='127.0.0.1:10085',
        help='Адрес Xray Stats API (по умолчанию: 127.0.0.1:10085)'
    )
    
    parser.add_argument(
        '--port',
        type=int,
        default=9090,
        help='Порт для Prometheus exporter (по умолчанию: 9090)'
    )
    
    args = parser.parse_args()
    
    # Создаем компоненты
    client = XrayStatsClient(server=args.server)
    aggregator = TrafficAggregator()
    
    # Console renderer (если нужен)
    renderer = ConsoleRenderer() if args.mode in ('console', 'both') else None
    
    # Prometheus exporter (если нужен)
    exporter = None
    if args.mode in ('prometheus', 'both'):
        exporter = PrometheusExporter(port=args.port)
        exporter.start(aggregator)
    
    # Запускаем основной цикл
    try:
        asyncio.run(monitoring_loop(client, aggregator, renderer, args.interval))
    except KeyboardInterrupt:
        print("\n✅ Завершено")
    finally:
        if exporter:
            exporter.stop()


if __name__ == '__main__':
    main()
