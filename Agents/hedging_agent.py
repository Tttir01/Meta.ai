"""
Hedging agent for MetaTrader 5 (runs on VPS). Reads credentials from environment variables or .env file.
Requires:
  pip install MetaTrader5 python-dotenv

Security:
  - Do NOT commit .env with real credentials.
  - Run on a trusted VPS (e.g. MQL5 VPS, DigitalOcean, AWS) and secure the server.

This script logs into MT5 via MetaTrader5 package, opens an initial BUY if none exists, and opens an opposite hedge
position if price moves against the initial position by HEDGE_DISTANCE_PIPS. It keeps running and attempts reconnects.
"""

import os
import time
import signal
import logging
from dotenv import load_dotenv

try:
    import MetaTrader5 as mt5
except Exception as e:
    raise SystemExit("MetaTrader5 package required. Run: pip install MetaTrader5 python-dotenv")

# Load .env if present
load_dotenv()

# Config from environment
MT5_LOGIN = int(os.getenv('MT5_LOGIN', '0'))
MT5_PASSWORD = os.getenv('MT5_PASSWORD', '')
MT5_SERVER = os.getenv('MT5_SERVER', '')
SYMBOL = os.getenv('SYMBOL', 'EURUSD')
LOT = float(os.getenv('LOT', '0.1'))
HEDGE_DISTANCE_PIPS = int(os.getenv('HEDGE_DISTANCE_PIPS', '50'))
SL_PIPS = int(os.getenv('SL_PIPS', '200'))
TP_PIPS = int(os.getenv('TP_PIPS', '400'))
MAGIC = int(os.getenv('MAGIC', '123456'))
DEVIATION = int(os.getenv('DEVIATION', '20'))

LOG_LEVEL = os.getenv('LOG_LEVEL', 'INFO')

logging.basicConfig(level=getattr(logging, LOG_LEVEL.upper(), logging.INFO), format='%(asctime)s %(levelname)s %(message)s')
logger = logging.getLogger('hedge_agent')

running = True


def handle_signal(sig, frame):
    global running
    logger.info('Received signal to stop (%s). Shutting down...', sig)
    running = False

signal.signal(signal.SIGINT, handle_signal)
signal.signal(signal.SIGTERM, handle_signal)


def connect():
    # initialize
    if not mt5.initialize():
        logger.error('mt5.initialize() failed, error=%s', mt5.last_error())
        return False
    # login
    if MT5_LOGIN and MT5_PASSWORD and MT5_SERVER:
        ok = mt5.login(MT5_LOGIN, password=MT5_PASSWORD, server=MT5_SERVER)
    elif MT5_LOGIN and MT5_PASSWORD:
        ok = mt5.login(MT5_LOGIN, password=MT5_PASSWORD)
    else:
        # If no credentials provided, assume terminal already logged in (useful for MQL5 VPS)
        logger.info('No credentials provided; assuming terminal is already logged in manually.')
        return True

    if not ok:
        logger.error('mt5.login failed: %s', mt5.last_error())
        return False

    logger.info('Connected to MT5. Account=%s Server=%s', MT5_LOGIN, MT5_SERVER)
    return True


def get_tick(symbol):
    tick = mt5.symbol_info_tick(symbol)
    if tick is None:
        return None
    return tick


def send_order(symbol, order_type, volume, price, sl, tp, deviation=DEVIATION):
    order = {
        'action': mt5.TRADE_ACTION_DEAL,
        'symbol': symbol,
        'volume': volume,
        'type': mt5.ORDER_TYPE_BUY if order_type == 'BUY' else mt5.ORDER_TYPE_SELL,
        'price': price,
        'sl': sl,
        'tp': tp,
        'deviation': deviation,
        'magic': MAGIC,
        'type_time': mt5.ORDER_TIME_GTC,
        'type_filling': mt5.ORDER_FILLING_FOK,
    }
    res = mt5.order_send(order)
    return res


def positions_for_magic(symbol):
    pos = mt5.positions_get(symbol=symbol)
    if pos is None:
        return []
    res = []
    for p in pos:
        try:
            if int(p.magic) == MAGIC:
                res.append(p)
        except Exception:
            # not all brokers expose magic; fallback to include all opened by this script's account
            res.append(p)
    return res


def open_initial_buy(symbol):
    tick = get_tick(symbol)
    if tick is None:
        logger.error('No tick for %s', symbol)
        return None
    ask = tick.ask
    point = mt5.symbol_info(symbol).point
    digits = mt5.symbol_info(symbol).digits
    sl = round(ask - SL_PIPS * point, digits)
    tp = round(ask + TP_PIPS * point, digits)
    res = send_order(symbol, 'BUY', LOT, ask, sl, tp)
    logger.info('OpenInitialBuy result=%s', res)
    return res


def open_hedge_sell(symbol):
    tick = get_tick(symbol)
    if tick is None:
        logger.error('No tick for %s', symbol)
        return None
    bid = tick.bid
    point = mt5.symbol_info(symbol).point
    digits = mt5.symbol_info(symbol).digits
    sl = round(bid + SL_PIPS * point, digits)
    tp = round(bid - TP_PIPS * point, digits)
    res = send_order(symbol, 'SELL', LOT, bid, sl, tp)
    logger.info('OpenHedgeSell result=%s', res)
    return res


def main_loop():
    global running
    reconnect_wait = 5
    while running:
        try:
            if not connect():
                logger.warning('Connect failed; retry in %s seconds', reconnect_wait)
                time.sleep(reconnect_wait)
                continue

            # ensure symbol available
            if not mt5.symbol_select(SYMBOL, True):
                logger.error('symbol_select failed for %s', SYMBOL)
                time.sleep(5)
                continue

            while running:
                positions = positions_for_magic(SYMBOL)
                tick = get_tick(SYMBOL)
                if tick is None:
                    logger.warning('No tick; retry')
                    time.sleep(1)
                    continue

                ask, bid = tick.ask, tick.bid

                if not positions:
                    logger.info('No positions found for magic=%s on %s, opening initial BUY', MAGIC, SYMBOL)
                    open_initial_buy(SYMBOL)
                else:
                    # check each position, if price moved against by HEDGE_DISTANCE_PIPS, open opposite
                    for p in positions:
                        p_type = p.type
                        p_open = p.price_open
                        point = mt5.symbol_info(SYMBOL).point
                        if p_type == mt5.ORDER_TYPE_BUY or p_type == 0:
                            dist = abs(bid - p_open) / point
                            if dist >= HEDGE_DISTANCE_PIPS:
                                logger.info('BUY position moved against by %s pips -> opening SELL hedge', dist)
                                open_hedge_sell(SYMBOL)
                        elif p_type == mt5.ORDER_TYPE_SELL or p_type == 1:
                            dist = abs(ask - p_open) / point
                            if dist >= HEDGE_DISTANCE_PIPS:
                                logger.info('SELL position moved against by %s pips -> opening BUY hedge', dist)
                                open_initial_buy(SYMBOL)

                time.sleep(5)

        except Exception as ex:
            logger.exception('Exception in main loop: %s', ex)
            time.sleep(5)

    try:
        mt5.shutdown()
    except Exception:
        pass
    logger.info('Agent stopped')


if __name__ == '__main__':
    main_loop()
