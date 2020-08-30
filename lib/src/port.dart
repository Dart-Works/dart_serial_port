/*
 * This file is based on libserialport (https://sigrok.org/wiki/Libserialport).
 *
 * Copyright (C) 2010-2012 Bert Vermeulen <bert@biot.com>
 * Copyright (C) 2010-2015 Uwe Hermann <uwe@hermann-uwe.de>
 * Copyright (C) 2013-2015 Martin Ling <martin-libserialport@earth.li>
 * Copyright (C) 2013 Matthias Heidbrink <m-sigrok@heidbrink.biz>
 * Copyright (C) 2014 Aurelien Jacobs <aurel@gnuage.org>
 * Copyright (C) 2020 J-P Nurmi <jpnurmi@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi;
import 'package:serial_port/src/bindings.dart';
import 'package:serial_port/src/config.dart';
import 'package:serial_port/src/dylib.dart';
import 'package:serial_port/src/enums.dart';
import 'package:serial_port/src/utf8.dart';
import 'package:meta/meta.dart';

typedef int _SerialReader(ffi.Pointer<ffi.Uint8> ptr);
typedef int _SerialWriter(ffi.Pointer<ffi.Uint8> ptr);

abstract class SerialPort {
  factory SerialPort(String name) => _SerialPortImpl(name);

  SerialPort copy();

  static List<String> get availablePorts => _SerialPortImpl.availablePorts;

  @mustCallSuper
  void dispose();

  bool open(int mode);
  bool close();

  String get name;
  String get description;
  int get transport;
  int get busNumber;
  int get deviceNumber;
  int get vendorId;
  int get productId;
  String get manufacturer;
  String get productName;
  String get serialNumber;
  String get macAddress;

  // ### TODO: disposal
  SerialPortConfig get config;
  void set config(SerialPortConfig config);

  Stream<Uint8List> get onReceive;
  Future<Uint8List> read(int bytes, {int timeout = 0});
  Uint8List readSync(int bytes, {int timeout = 0});

  Future<int> write(Uint8List bytes);
  int writeSync(Uint8List bytes, {int timeout = 0});

  int get inputWaiting;
  int get outputWaiting;

  void flush(int buffers);
  void drain();

  // ### TODO: events

  int get signals;

  bool startBreak();
  bool endBreak();

  static int get lastErrorCode => _SerialPortImpl.lastErrorCode;
  static String get lastErrorMessage => _SerialPortImpl.lastErrorMessage;
}

void _sp_call(Function sp_func) {
  if (sp_func() < sp_return.SP_OK) {
    // TODO: SerialPortError
    throw OSError(SerialPort.lastErrorMessage, SerialPort.lastErrorCode);
  }
}

class _SerialPortImpl implements SerialPort {
  final ffi.Pointer<sp_port> _port;

  _SerialPortImpl(String name) : _port = _init(name) {}
  _SerialPortImpl.fromNative(this._port);
  ffi.Pointer<sp_port> toNative() => _port;

  static ffi.Pointer<sp_port> _init(String name) {
    final out = ffi.allocate<ffi.Pointer<sp_port>>();
    final cstr = Utf8.toUtf8(name);
    _sp_call(() => dylib.sp_get_port_by_name(cstr, out));
    final port = out[0];
    ffi.free(out);
    ffi.free(cstr);
    return port;
  }

  SerialPort copy() {
    final out = ffi.allocate<ffi.Pointer<sp_port>>();
    _sp_call(() => dylib.sp_copy_port(_port, out));
    final port = _SerialPortImpl.fromNative(out[0]);
    ffi.free(out);
    return port;
  }

  static List<String> get availablePorts {
    final out = ffi.allocate<ffi.Pointer<ffi.Pointer<sp_port>>>();
    _sp_call(() => dylib.sp_list_ports(out));
    var i = -1;
    var ports = <String>[];
    final array = out.value;
    while (array[++i].address != 0x0) {
      ports.add(Utf8.fromUtf8(dylib.sp_get_port_name(array[i])));
    }
    dylib.sp_free_port_list(array);
    return ports;
  }

  @mustCallSuper
  void dispose() => dylib.sp_free_port(_port);

  Isolate _reader;
  final _controller = StreamController<Uint8List>();
  Stream<Uint8List> get onReceive => _controller.stream;

  static void _sp_reader(Map args) {
    final int address = args['address'];
    final SendPort sendPort = args['sendPort'];
    final ffi.Pointer<sp_port> port = ffi.Pointer<sp_port>.fromAddress(address);
    final ffi.Pointer<ffi.Pointer<sp_event_set>> events = ffi.allocate();
    dylib.sp_new_event_set(events);
    dylib.sp_add_port_events(events.value, port, sp_event.SP_EVENT_RX_READY);
    while (true) {
      dylib.sp_wait(events.value, 500);
      final bytes = dylib.sp_input_waiting(port);
      if (bytes == sp_return.SP_ERR_ARG) {
        break;
      }
      if (bytes > 0) {
        final data = _read(bytes, (ffi.Pointer<ffi.Uint8> ptr) {
          return dylib.sp_nonblocking_read(port, ptr.cast(), bytes);
        });
        sendPort.send(data);
      }
    }
  }

  bool open(int mode) {
    if (mode == SerialPortMode.read || mode == SerialPortMode.readWrite) {
      final receiver = ReceivePort();
      receiver.listen((data) => _controller.add(data));
      final args = {'address': _port.address, 'sendPort': receiver.sendPort};
      Isolate.spawn(_sp_reader, args).then((reader) => _reader = reader);
    }
    return dylib.sp_open(_port, mode) == sp_return.SP_OK;
  }

  bool close() {
    _reader?.kill();
    _reader = null;
    return dylib.sp_close(_port) == sp_return.SP_OK;
  }

  String get name => Utf8.fromUtf8(dylib.sp_get_port_name(_port));
  String get description {
    return Utf8.fromUtf8(dylib.sp_get_port_description(_port));
  }

  int get transport => dylib.sp_get_port_transport(_port);

  int get busNumber {
    final ptr = ffi.allocate<ffi.Int32>();
    _sp_call(() => dylib.sp_get_port_usb_bus_address(_port, ptr, ffi.nullptr));
    final bus = ptr.value;
    ffi.free(ptr);
    return bus;
  }

  int get deviceNumber {
    final ptr = ffi.allocate<ffi.Int32>();
    _sp_call(() => dylib.sp_get_port_usb_bus_address(_port, ffi.nullptr, ptr));
    final address = ptr.value;
    ffi.free(ptr);
    return address;
  }

  int get vendorId {
    final ptr = ffi.allocate<ffi.Int32>();
    _sp_call(() => dylib.sp_get_port_usb_vid_pid(_port, ptr, ffi.nullptr));
    final id = ptr.value;
    ffi.free(ptr);
    return id;
  }

  int get productId {
    final ptr = ffi.allocate<ffi.Int32>();
    _sp_call(() => dylib.sp_get_port_usb_vid_pid(_port, ffi.nullptr, ptr));
    final id = ptr.value;
    ffi.free(ptr);
    return id;
  }

  String get manufacturer {
    return Utf8.fromUtf8(dylib.sp_get_port_usb_manufacturer(_port));
  }

  String get productName {
    return Utf8.fromUtf8(dylib.sp_get_port_usb_product(_port));
  }

  String get serialNumber {
    return Utf8.fromUtf8(dylib.sp_get_port_usb_serial(_port));
  }

  String get macAddress {
    return Utf8.fromUtf8(dylib.sp_get_port_bluetooth_address(_port));
  }

  // ### TODO: disposal
  SerialPortConfig get config {
    final config = ffi.allocate<sp_port_config>();
    _sp_call(() => dylib.sp_get_config(_port, config));
    return SerialPortConfig.fromNative(config);
  }

  void set config(SerialPortConfig config) {
    _sp_call(() => dylib.sp_set_config(_port, config.toNative()));
  }

  static Uint8List _read(int bytes, _SerialReader reader) {
    final ptr = ffi.allocate<ffi.Uint8>(count: bytes);
    var len = 0;
    _sp_call(() => len = reader(ptr));
    final res = Uint8List.fromList(ptr.asTypedList(len));
    ffi.free(ptr);
    return res;
  }

  Future<Uint8List> read(int bytes, {int timeout = 0}) async {
    return _read(bytes, (ffi.Pointer<ffi.Uint8> ptr) {
      return dylib.sp_nonblocking_read(_port, ptr.cast(), bytes);
    });
  }

  Uint8List readSync(int bytes, {int timeout = 0}) {
    return _read(bytes, (ffi.Pointer<ffi.Uint8> ptr) {
      return dylib.sp_blocking_read(_port, ptr.cast(), bytes, timeout);
    });
  }

  static int _write(Uint8List bytes, _SerialWriter writer) {
    final len = bytes.length;
    final ptr = ffi.allocate<ffi.Uint8>(count: len);
    ptr.asTypedList(len).setAll(0, bytes);
    var res = 0;
    _sp_call(() => res = writer(ptr));
    ffi.free(ptr);
    return res;
  }

  Future<int> write(Uint8List bytes) async {
    return _write(bytes, (ffi.Pointer<ffi.Uint8> ptr) {
      return dylib.sp_nonblocking_write(_port, ptr.cast(), bytes.length);
    });
  }

  int writeSync(Uint8List bytes, {int timeout = 0}) {
    return _write(bytes, (ffi.Pointer<ffi.Uint8> ptr) {
      return dylib.sp_blocking_write(_port, ptr.cast(), bytes.length, timeout);
    });
  }

  int get inputWaiting => dylib.sp_input_waiting(_port);
  int get outputWaiting => dylib.sp_output_waiting(_port);

  void flush(int buffers) => dylib.sp_flush(_port, buffers);
  void drain() => dylib.sp_drain(_port);

  // ### TODO: events

  int get signals {
    final ptr = ffi.allocate<ffi.Int32>();
    _sp_call(() => dylib.sp_get_signals(_port, ptr));
    final value = ptr.value;
    ffi.free(ptr);
    return value;
  }

  bool startBreak() => dylib.sp_start_break(_port) == sp_return.SP_OK;
  bool endBreak() => dylib.sp_end_break(_port) == sp_return.SP_OK;

  static int get lastErrorCode => dylib.sp_last_error_code();

  static String get lastErrorMessage {
    final ptr = dylib.sp_last_error_message();
    final str = Utf8.fromUtf8(ptr);
    dylib.sp_free_error_message(ptr);
    return str;
  }

  @override
  bool operator ==(Object other) {
    if (other.runtimeType != runtimeType) return false;
    _SerialPortImpl port = other;
    return _port == port._port;
  }

  @override
  int get hashCode => _port.hashCode;

  @override
  String toString() => '$runtimeType($_port)';
}
