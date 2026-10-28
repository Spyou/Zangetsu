// Copyright 2018 The Android Open Source Project
// Licensed under the Apache License, Version 2.0. See LICENSE-Apache-2.0.txt.
// KMP port changes: Copyright (c) 2023 Jordon de Hoog, MIT License.
// Dart adaptation; complete notices are in assets/licenses/adaptive_palette.txt.

import 'dart:typed_data';

import 'package:flutter/painting.dart';

typedef _Swatch = ({Color color, int population});

/// Select a background swatch from a small, unpremultiplied RGBA thumbnail.
Color? adaptiveDominantColor(Uint8List rgba) {
  if (rgba.length % 4 != 0) {
    throw ArgumentError.value(rgba.length, 'rgba', 'Expected complete pixels');
  }
  if (rgba.isEmpty) return null;
  final quantizer = _Quantizer(rgba);
  final swatches = quantizer.generate();
  Color? selected;
  var population = -1;
  for (final swatch in swatches) {
    if (swatch.population <= population) continue;
    final hsl = quantizer.hsl.convert(swatch.color);
    if (hsl.lightness >= quantizer.hsl.f32(0.22) &&
        hsl.lightness <= quantizer.hsl.f32(0.92) &&
        hsl.saturation >= quantizer.hsl.f32(0.08)) {
      selected = swatch.color;
      population = swatch.population;
    }
  }
  return selected;
}

Color _rgb(int packed) => Color.fromARGB(
  255,
  ((packed >> 10) & 31) << 3,
  ((packed >> 5) & 31) << 3,
  (packed & 31) << 3,
);

// Source filtering uses Float32 operations; double precision changes boundary swatches.
class _Hsl {
  final _scratch = Float32List(1);

  double f32(double value) {
    _scratch[0] = value;
    return _scratch[0];
  }

  ({double hue, double saturation, double lightness}) convert(Color color) {
    final argb = color.toARGB32();
    final r = f32(((argb >> 16) & 255) / 255);
    final g = f32(((argb >> 8) & 255) / 255);
    final b = f32((argb & 255) / 255);
    final max = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final min = r < g ? (r < b ? r : b) : (g < b ? g : b);
    final delta = f32(max - min);
    final lightness = f32(f32(max + min) / 2);
    if (max == min) return (hue: 0, saturation: 0, lightness: lightness);
    var hue = max == r
        ? f32(f32(g - b) / delta).remainder(6)
        : max == g
        ? f32(f32(f32(b - r) / delta) + 2)
        : f32(f32(f32(r - g) / delta) + 4);
    final saturation = f32(delta / f32(1 - f32(f32(2 * lightness) - 1).abs()));
    hue = f32(hue * 60).remainder(360);
    if (hue < 0) hue = f32(hue + 360);
    return (
      hue: hue.clamp(0, 360),
      saturation: saturation.clamp(0, 1),
      lightness: lightness.clamp(0, 1),
    );
  }

  bool allowed(Color color) {
    final hsl = convert(color);
    return hsl.lightness > f32(0.05) &&
        hsl.lightness < f32(0.95) &&
        !(hsl.hue >= 10 && hsl.hue <= 37 && hsl.saturation <= f32(0.82));
  }
}

class _Quantizer {
  _Quantizer(Uint8List rgba) {
    for (var i = 0; i < rgba.length; i += 4) {
      final color =
          ((rgba[i] >> 3) << 10) |
          ((rgba[i + 1] >> 3) << 5) |
          (rgba[i + 2] >> 3);
      histogram[color]++;
    }
    for (var color = 0; color < histogram.length; color++) {
      if (histogram[color] == 0) continue;
      if (hsl.allowed(_rgb(color))) {
        colors.add(color);
      } else {
        histogram[color] = 0;
      }
    }
  }

  final hsl = _Hsl();
  final histogram = Uint32List(1 << 15);
  final colors = <int>[];

  List<_Swatch> generate() {
    if (colors.length <= 16) {
      return [
        for (final color in colors)
          (color: _rgb(color), population: histogram[color]),
      ];
    }
    final queue = _BoxQueue()..add(_Box(this, 0, colors.length - 1));
    while (queue.items.length < 16) {
      final box = queue.removeFirst();
      if (box == null || box.lower == box.upper) break;
      queue.add(box.split());
      queue.add(box);
    }
    final swatches = <_Swatch>[];
    for (final box in queue.items) {
      final average = box.average;
      if (hsl.allowed(average.color)) swatches.add(average);
    }
    return swatches;
  }
}

class _Box {
  _Box(this.quantizer, this.lower, this.upper) {
    fit();
  }

  final _Quantizer quantizer;
  final int lower;
  int upper;
  final minimum = List<int>.filled(3, 31);
  final maximum = List<int>.filled(3, 0);
  int population = 0;

  int get volume =>
      (maximum[0] - minimum[0] + 1) *
      (maximum[1] - minimum[1] + 1) *
      (maximum[2] - minimum[2] + 1);

  void fit() {
    minimum.fillRange(0, 3, 31);
    maximum.fillRange(0, 3, 0);
    population = 0;
    for (var i = lower; i <= upper; i++) {
      final color = quantizer.colors[i];
      population += quantizer.histogram[color];
      for (var channel = 0; channel < 3; channel++) {
        final value = (color >> (10 - channel * 5)) & 31;
        if (value < minimum[channel]) minimum[channel] = value;
        if (value > maximum[channel]) maximum[channel] = value;
      }
    }
  }

  _Box split() {
    final red = maximum[0] - minimum[0];
    final green = maximum[1] - minimum[1];
    final blue = maximum[2] - minimum[2];
    final dimension = red >= green && red >= blue
        ? 0
        : green >= red && green >= blue
        ? 1
        : 2;
    final subset = [
      for (var i = lower; i <= upper; i++)
        _swap(quantizer.colors[i], dimension),
    ]..sort();
    for (var i = 0; i < subset.length; i++) {
      quantizer.colors[lower + i] = _swap(subset[i], dimension);
    }
    final midpoint = population ~/ 2;
    var count = 0;
    var splitIndex = lower;
    for (var i = lower; i <= upper; i++) {
      count += quantizer.histogram[quantizer.colors[i]];
      if (count >= midpoint) {
        splitIndex = i < upper ? i : upper - 1;
        break;
      }
    }
    final next = _Box(quantizer, splitIndex + 1, upper);
    upper = splitIndex;
    fit();
    return next;
  }

  _Swatch get average {
    final sums = List<int>.filled(3, 0);
    for (var i = lower; i <= upper; i++) {
      final color = quantizer.colors[i];
      final count = quantizer.histogram[color];
      for (var channel = 0; channel < 3; channel++) {
        sums[channel] += count * ((color >> (10 - channel * 5)) & 31);
      }
    }
    return (
      color: Color.fromARGB(
        255,
        _mean(sums[0], population) << 3,
        _mean(sums[1], population) << 3,
        _mean(sums[2], population) << 3,
      ),
      population: population,
    );
  }
}

int _swap(int color, int dimension) => switch (dimension) {
  1 => (((color >> 5) & 31) << 10) | (((color >> 10) & 31) << 5) | (color & 31),
  2 => ((color & 31) << 10) | (color & (31 << 5)) | ((color >> 10) & 31),
  _ => color,
};

// Preserve the reference's round-to-even averages instead of rounding ties up.
int _mean(int sum, int count) {
  final value = sum ~/ count;
  final twiceRemainder = (sum % count) * 2;
  return twiceRemainder > count || (twiceRemainder == count && value.isOdd)
      ? value + 1
      : value;
}

// Equal-volume boxes must keep the same heap ordering as the source port.
class _BoxQueue {
  final items = <_Box>[];

  void add(_Box box) {
    items.add(box);
    var index = items.length - 1;
    while (index > 0) {
      final parent = (index - 1) ~/ 2;
      if (items[parent].volume >= items[index].volume) break;
      final previous = items[parent];
      items[parent] = items[index];
      items[index] = previous;
      index = parent;
    }
  }

  _Box? removeFirst() {
    if (items.isEmpty) return null;
    final first = items.first;
    final last = items.removeLast();
    if (items.isEmpty) return first;
    items[0] = last;
    var index = 0;
    while (index * 2 + 1 < items.length) {
      var child = index * 2 + 1;
      if (child + 1 < items.length &&
          items[child + 1].volume >= items[child].volume) {
        child++;
      }
      if (items[child].volume <= items[index].volume) break;
      final previous = items[index];
      items[index] = items[child];
      items[child] = previous;
      index = child;
    }
    return first;
  }
}
