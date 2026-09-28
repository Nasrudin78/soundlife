import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:html/dom.dart';
import 'package:html/parser.dart' show parse;

/// Datos de un producto de soundandlife.com.
class ProductInfo {
  final String? title; // ej. "BA07 Rescate – Ansiedad"
  final String? imageUrl;
  const ProductInfo({this.title, this.imageUrl});
}

class ScraperService {
  static final RegExp _idRegex = RegExp(r'BA[-\s_]?(\d+)', caseSensitive: false);

  /// Extrae y normaliza el identificador de un nombre de fichero
  /// (ej. "ba-7 rescate.mp3" -> "BA07"). Devuelve '' si no hay.
  static String extractIdentifier(String text) {
    final match = _idRegex.firstMatch(text);
    if (match == null) return '';
    return 'BA${int.parse(match.group(1)!).toString().padLeft(2, '0')}';
  }

  /// Busca el producto por identificador (ej. BA01) y devuelve su nombre y carátula.
  static Future<ProductInfo?> fetchProduct(String identifier) async {
    final id = extractIdentifier(identifier);
    if (id.isEmpty) return null;
    final number = int.parse(id.substring(2));

    try {
      final url = Uri.parse('https://soundandlife.com/?s=$id&post_type=product');
      final response = await http.get(url, headers: {'User-Agent': 'Mozilla/5.0 (Linux; Android) SoundLife'});
      if (response.statusCode != 200) return null;

      final document = parse(response.body);

      // Con un único resultado WooCommerce redirige a la ficha del producto
      final productTitle = document.querySelector('h1.product_title');
      if (productTitle != null) {
        if (!_titleMatches(productTitle.text, number)) return null;
        final img = document.querySelector('img.wp-post-image') ??
            document.querySelector('.woocommerce-product-gallery img');
        return ProductInfo(title: _clean(productTitle.text), imageUrl: _imageSrc(img, preferLarge: true));
      }

      // Listado de resultados: elegir el producto cuyo título empieza por el identificador
      for (final product in document.querySelectorAll('li.product')) {
        final title = product.querySelector('.woocommerce-loop-product__title')?.text ?? '';
        if (!_titleMatches(title, number)) continue;
        final img = product.querySelector('img.woo-entry-image-main') ?? product.querySelector('img');
        return ProductInfo(title: _clean(title), imageUrl: _imageSrc(img));
      }
    } catch (e) {
      debugPrint('Error al obtener carátula para $identifier: $e');
    }
    return null;
  }

  static String? _clean(String text) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.isEmpty ? null : t;
  }

  static bool _titleMatches(String title, int number) {
    final match = RegExp(r'^\s*BA[-\s_]?(\d+)', caseSensitive: false).firstMatch(title);
    return match != null && int.parse(match.group(1)!) == number;
  }

  static String? _imageSrc(Element? img, {bool preferLarge = false}) {
    if (img == null) return null;
    final candidates = [
      if (preferLarge) img.attributes['data-large_image'],
      img.attributes['src'],
      img.attributes['data-src'],
    ];
    for (final src in candidates) {
      if (src != null && src.isNotEmpty && !src.startsWith('data:')) return src;
    }
    return null;
  }
}
