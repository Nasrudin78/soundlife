import 'package:html/dom.dart';

/// Tipo de bloque de texto de una ficha, para reproducir el formato de la web.
enum BlockType { paragraph, heading, bullet, image }

class DetailBlock {
  final BlockType type;
  final String text; // los saltos de línea (<br>) se conservan como '\n'; en imágenes, su URL
  final bool bold;
  final bool italic;
  final bool center;
  final String? path; // copia local de la imagen

  const DetailBlock(this.type, this.text, {this.bold = false, this.italic = false, this.center = false, this.path});

  DetailBlock withPath(String path) => DetailBlock(type, text, bold: bold, italic: italic, center: center, path: path);

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'text': text,
        if (bold) 'bold': true,
        if (italic) 'italic': true,
        if (center) 'center': true,
        if (path != null) 'path': path,
      };

  factory DetailBlock.fromJson(Map<String, dynamic> json) => DetailBlock(
        BlockType.values.firstWhere((t) => t.name == json['type'], orElse: () => BlockType.paragraph),
        json['text'] ?? '',
        bold: json['bold'] ?? false,
        italic: json['italic'] ?? false,
        center: json['center'] ?? false,
        path: json['path'],
      );
}

/// Un apartado de la ficha: Descripción, Aplicaciones o Posología.
class DetailSection {
  final String title;
  final List<DetailBlock> blocks;
  const DetailSection(this.title, this.blocks);

  Map<String, dynamic> toJson() => {'title': title, 'blocks': blocks.map((b) => b.toJson()).toList()};

  factory DetailSection.fromJson(Map<String, dynamic> json) => DetailSection(
        json['title'] ?? '',
        [for (final b in (json['blocks'] as List? ?? [])) DetailBlock.fromJson(Map<String, dynamic>.from(b))],
      );
}

/// Ficha de un sonido de soundandlife.com, guardada en el móvil para verla sin conexión.
class ProductDetails {
  final String? headline; // para qué sirve, en una línea
  final List<DetailSection> sections;
  const ProductDetails({this.headline, required this.sections});

  bool get isEmpty => headline == null && sections.isEmpty;

  Map<String, dynamic> toJson() => {
        'headline': headline,
        'sections': sections.map((s) => s.toJson()).toList(),
      };

  factory ProductDetails.fromJson(Map<String, dynamic> json) => ProductDetails(
        headline: json['headline'],
        sections: [
          for (final s in (json['sections'] as List? ?? [])) DetailSection.fromJson(Map<String, dynamic>.from(s)),
        ],
      );

  static const _tabs = {
    'tab-description': 'Descripción',
    'tab-aplicaciones': 'Aplicaciones',
    'tab-posologia': 'Posología',
  };
  static const int _headlineMax = 90;

  /// Extrae la ficha de la página de un producto WooCommerce.
  static ProductDetails parse(Document document) {
    final sections = <DetailSection>[];
    _tabs.forEach((id, fallbackTitle) {
      final panel = document.getElementById(id);
      if (panel == null) return;
      final title = _norm(panel.querySelector('h2')?.text ?? '');
      final blocks = <DetailBlock>[];
      _collect(panel, blocks);
      if (blocks.isNotEmpty) sections.add(DetailSection(title.isEmpty ? fallbackTitle : title, blocks));
    });
    return ProductDetails(headline: _headline(document), sections: sections);
  }

  /// Primera frase del resumen corto de la web, cortada a una línea.
  static String? _headline(Document document) {
    final short = document.querySelector('.woocommerce-product-details__short-description');
    if (short == null) return null;
    final lines = _lines(short).where((l) => l.length > 3).toList();
    if (lines.isEmpty) return null;
    var line = lines.first.replaceAll(RegExp(r'[.…]+$'), '');
    if (line.length > _headlineMax) {
      final cut = line.lastIndexOf(' ', _headlineMax);
      line = '${line.substring(0, cut > 40 ? cut : _headlineMax).replaceAll(RegExp(r'[\s,;:–-]+$'), '')}…';
    }
    return line;
  }

  /// Recorre el panel en orden y crea un bloque por párrafo, elemento de lista o subtítulo.
  static void _collect(Element parent, List<DetailBlock> out) {
    for (final node in parent.nodes) {
      if (node is Text) {
        final text = _norm(node.text);
        if (text.isNotEmpty) out.add(DetailBlock(BlockType.paragraph, text));
        continue;
      }
      if (node is! Element) continue;
      switch (node.localName) {
        case 'h2':
        case 'script':
        case 'style':
        case 'img':
        case 'audio':
        case 'figure':
          continue;
        case 'h1':
        case 'h3':
        case 'h4':
        case 'h5':
        case 'h6':
          final text = _norm(node.text);
          if (text.isNotEmpty) out.add(DetailBlock(BlockType.heading, text));
        case 'ul':
        case 'ol':
          for (final li in node.children.where((c) => c.localName == 'li')) {
            final text = _lines(li).join('\n');
            if (text.isNotEmpty) out.add(DetailBlock(BlockType.bullet, text));
          }
        case 'div':
        case 'section':
        case 'blockquote':
          _collect(node, out);
        default:
          _paragraph(node, out);
      }
    }
  }

  static void _paragraph(Element p, List<DetailBlock> out) {
    final lines = _lines(p);
    if (lines.isNotEmpty) _text(p, lines, out);
    for (final img in p.querySelectorAll('img')) {
      final src = _imageSrc(img);
      if (src != null) out.add(DetailBlock(BlockType.image, src));
    }
  }

  /// URL de una imagen, prefiriendo la versión de ~1024 px del srcset (nítida y no muy pesada).
  static String? _imageSrc(Element img) {
    final srcset = img.attributes['srcset'];
    if (srcset != null) {
      for (final candidate in srcset.split(',')) {
        final parts = candidate.trim().split(RegExp(r'\s+'));
        if (parts.length == 2 && parts[1] == '1024w') return parts[0];
      }
    }
    final src = img.attributes['src'] ?? img.attributes['data-src'];
    return src == null || src.isEmpty || src.startsWith('data:') ? null : src;
  }

  static void _text(Element p, List<String> lines, List<DetailBlock> out) {
    final total = _norm(p.text).length;
    final bold = _formattedLength(p, const {'strong', 'b'}) >= total * 0.9;
    final italic = _formattedLength(p, const {'em', 'i'}) >= total * 0.9;
    final center = (p.attributes['style'] ?? '').contains('center');

    // Párrafo de una línea en negrita o acabado en ':' ("Importante:", "APLICACIONES TERAPÉUTICAS"): subtítulo
    if (lines.length == 1 && lines.first.length <= 60 && (bold || lines.first.endsWith(':'))) {
      out.add(DetailBlock(BlockType.heading, lines.first, center: center));
      return;
    }

    // "Consejo:", "Nota:"… al principio de un párrafo se muestran como subtítulo
    if (lines.length > 1 && lines.first.endsWith(':') && lines.first.length <= 40) {
      out.add(DetailBlock(BlockType.heading, lines.first));
      lines.removeAt(0);
      final rest = p.querySelectorAll('em, i').map((e) => _norm(e.text)).join(' ');
      final restItalic = italic || (rest.isNotEmpty && rest.length >= lines.join(' ').length * 0.9);
      out.add(DetailBlock(BlockType.paragraph, lines.join('\n'), bold: bold, italic: restItalic, center: center));
      return;
    }
    out.add(DetailBlock(BlockType.paragraph, lines.join('\n'), bold: bold, italic: italic, center: center));
  }

  static int _formattedLength(Element e, Set<String> tags) =>
      e.querySelectorAll(tags.join(', ')).where((x) => !tags.contains(x.parent?.localName)).fold(
            0,
            (sum, x) => sum + _norm(x.text).length,
          );

  /// Texto de un elemento dividido por sus <br>, sin líneas vacías.
  static List<String> _lines(Element e) {
    final html = e.innerHtml.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    final text = Element.html('<div>$html</div>').text;
    return text.split('\n').map(_norm).where((l) => l.isNotEmpty).toList();
  }

  static String _norm(String s) => s.replaceAll(' ', ' ').replaceAll(RegExp(r'[ \t\r\f\v]+'), ' ').trim();
}
