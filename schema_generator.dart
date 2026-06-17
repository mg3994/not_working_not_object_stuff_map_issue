import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

const schemaUrl = 'https://schema.org/version/latest/schemaorg-current-https.jsonld';

Future<void> main() async {
  print('Fetching schema from $schemaUrl...');
  final response = await http.get(Uri.parse(schemaUrl));
  if (response.statusCode != 200) {
    print('Failed to fetch schema: ${response.statusCode}');
    return;
  }

  final data = json.decode(response.body);
  final graph = data['@graph'] as List;

  final classes = <String, Map<String, dynamic>>{};
  final properties = <String, Map<String, dynamic>>{};
  final enumerations = <String, Map<String, dynamic>>{};
  final enumerationValues = <String, List<String>>{};
  final dataTypes = <String, Map<String, dynamic>>{};

  for (final item in graph) {
    final id = item['@id'] as String;
    if (!id.startsWith('schema:')) continue; 

    final type = item['@type'];

    if (type == 'rdfs:Class' || (type is List && type.contains('rdfs:Class'))) {
      final subClassOf = item['rdfs:subClassOf'];
      bool isEnum = false;
      if (subClassOf != null) {
        bool checkEnum(dynamic s) {
          if (s is Map && s['@id'] == 'schema:Enumeration') return true;
          if (s is List) return s.any((e) => checkEnum(e));
          return false;
        }
        isEnum = checkEnum(subClassOf);
      }
      
      if (isEnum) {
        enumerations[id] = item;
      } else if (type is List && type.contains('schema:DataType')) {
        dataTypes[id] = item;
      } else {
        classes[id] = item;
      }
    } else if (type == 'rdf:Property' || (type is List && type.contains('rdf:Property'))) {
      properties[id] = item;
    } else if (type is String && type.startsWith('schema:')) {
       enumerationValues.putIfAbsent(type, () => []).add(id);
    } else if (type is List) {
       for(var t in type) {
         if (t is String && t.startsWith('schema:')) {
           enumerationValues.putIfAbsent(t, () => []).add(id);
         }
       }
    }
  }

  print('Found ${classes.length} classes, ${properties.length} properties, ${enumerations.length} enumerations, and ${dataTypes.length} data types.');

  final propertyRanges = <String, List<String>>{};
  for (final id in properties.keys) {
    final item = properties[id]!;
    final range = item['schema:rangeIncludes'];
    if (range != null) {
      if (range is Map) {
        propertyRanges[id] = [range['@id']];
      } else if (range is List) {
        propertyRanges[id] = range.map((e) => e['@id'] as String).toList();
      }
    }
  }

  final classProperties = <String, List<String>>{};
  for (final propId in properties.keys) {
    final domain = properties[propId]!['schema:domainIncludes'];
    final domains = <String>[];
    if (domain is Map) {
      domains.add(domain['@id']);
    } else if (domain is List) {
      domains.addAll(domain.map((e) => e['@id'] as String));
    }
    for (final d in domains) {
      classProperties.putIfAbsent(d, () => []).add(propId);
    }
  }

  final classParents = <String, List<String>>{};
  for (final id in [...classes.keys, ...enumerations.keys, ...dataTypes.keys]) {
    final item = classes[id] ?? enumerations[id] ?? dataTypes[id]!;
    final subClassOf = item['rdfs:subClassOf'];
    if (subClassOf != null) {
      if (subClassOf is Map) {
        final pid = subClassOf['@id'] as String;
        if (pid.startsWith('schema:')) classParents[id] = [pid];
      } else if (subClassOf is List) {
        classParents[id] = subClassOf
            .map((e) => e['@id'] as String)
            .where((pid) => pid.startsWith('schema:'))
            .toList();
      }
    }
  }

  // Precompute full property list per class (including inheritance)
  final classFullProperties = <String, Set<String>>{};
  Set<String> getFullProperties(String classId) {
    if (classFullProperties.containsKey(classId)) return classFullProperties[classId]!;
    final props = <String>{};
    props.addAll(classProperties[classId] ?? []);
    final parents = classParents[classId] ?? [];
    for (final parent in parents) {
      props.addAll(getFullProperties(parent));
    }
    classFullProperties[classId] = props;
    return props;
  }

  for (final classId in classes.keys) {
    getFullProperties(classId);
  }

  final reservedNames = {'Map', 'List', 'Set', 'Object', 'String', 'bool', 'num', 'int', 'double', 'DateTime', 'Duration', 'Type', 'Enum', 'Null'};

  String cleanName(String id) {
    String name = id.replaceFirst('schema:', '');
    if (name == 'Duration') return 'SchemaDuration';
    if (name.startsWith(RegExp(r'[0-9]'))) {
      name = 'Schema$name';
    }
    if (reservedNames.contains(name)) {
      name = 'Schema$name';
    }
    return name;
  }

  final sb = StringBuffer();
  sb.writeln("// ignore_for_file: unused_import, overridden_fields, annotate_overrides, constant_identifier_names, unnecessary_cast, override_on_non_overriding_member, non_constant_identifier_names");
  sb.writeln("import 'dart:convert';");
  sb.writeln("import 'package:json_annotation/json_annotation.dart';");
  sb.writeln("");

  // Base Class
  sb.writeln("abstract class SchemaOrgEntity {");
  sb.writeln("  @JsonKey(name: '@context')");
  sb.writeln("  String? get context => 'https://schema.org';");
  sb.writeln("  @JsonKey(name: '@type')");
  sb.writeln("  String get type;");
  sb.writeln("  @JsonKey(name: '@id')");
  sb.writeln("  String? id;");
  sb.writeln("");
  sb.writeln("  Map<String, dynamic> toJson();");
  sb.writeln("}");
  sb.writeln("");

  // Helper to get Dart type from Schema type
  String getDartType(String schemaId, String propId) {
    if (!schemaId.startsWith('schema:')) return 'Object';
    switch (schemaId) {
      case 'schema:Text': return 'String';
      case 'schema:Number':
      case 'schema:Integer':
      case 'schema:Float': return 'num';
      case 'schema:Boolean': return 'bool';
      case 'schema:URL': return 'String';
      case 'schema:Date':
      case 'schema:DateTime':
      case 'schema:Time': return 'String';
      default:
        return cleanName(schemaId);
    }
  }

  // Generate all as Classes
  final allTypes = {...classes, ...enumerations, ...dataTypes};
  for (final id in allTypes.keys) {
    final name = cleanName(id);
    final parents = classParents[id] ?? [];
    final props = classProperties[id] ?? [];
    final allAllowedProps = classFullProperties[id] ?? (props.toSet());

    String extendsClause = "";
    String implementsClause = "";
    bool hasSuper = false;
    if (parents.isNotEmpty) {
      extendsClause = "extends ${cleanName(parents.first)} ";
      if (parents.length > 1) {
        implementsClause = "implements " + parents.skip(1).map(cleanName).join(', ');
      }
      hasSuper = true;
    } else {
      extendsClause = "extends SchemaOrgEntity ";
      hasSuper = false;
    }

    sb.writeln("class $name $extendsClause$implementsClause {");
    sb.writeln("  @override");
    sb.writeln("  String get type => '${id.replaceFirst('schema:', '')}';");
    sb.writeln("");
    
    if (enumerations.containsKey(id)) {
       sb.writeln("  String? value;");
    }

    final seenProps = <String>{};
    for (final propId in props) {
      final propName = propId.replaceFirst('schema:', '');
      String fieldName = propName;
      if (reservedNames.contains(fieldName)) fieldName = 'schema$fieldName';
      
      if (seenProps.contains(fieldName)) continue;
      seenProps.add(fieldName);

      final ranges = (propertyRanges[propId] ?? []).where((r) => r.startsWith('schema:')).toList();
      
      if (ranges.length == 1) {
        final dType = getDartType(ranges.first, propId);
        sb.writeln("  $dType? $fieldName;");
      } else {
        sb.writeln("  Object? $fieldName;");
      }
    }

    sb.writeln("");
    sb.writeln("  $name();");
    sb.writeln("");
    
    sb.writeln("  @override");
    sb.writeln("  Map<String, dynamic> toJson() {");
    if (hasSuper) {
      sb.writeln("    final map = super.toJson();");
    } else {
      sb.writeln("    final map = <String, dynamic>{};");
      sb.writeln("    try { map['@context'] = (this as dynamic).context; } catch(_) {}");
    }
    sb.writeln("    map['@type'] = type;");
    sb.writeln("    if (id != null) map['@id'] = id;");
    if (enumerations.containsKey(id)) {
       sb.writeln("    if (value != null) map['value'] = value;");
    }
    for (final propId in props) {
      final propName = propId.replaceFirst('schema:', '');
      String fieldName = propName;
      if (reservedNames.contains(fieldName)) fieldName = 'schema$fieldName';

      sb.writeln("    if ($fieldName != null) {");
      sb.writeln("      final val = $fieldName;");
      sb.writeln("      if (val is SchemaOrgEntity) {");
      sb.writeln("        map['$propName'] = val.toJson();");
      sb.writeln("      } else if (val is List) {");
      sb.writeln("        map['$propName'] = val.map((e) => e is SchemaOrgEntity ? e.toJson() : e).toList();");
      sb.writeln("      } else {");
      sb.writeln("        map['$propName'] = val;");
      sb.writeln("      }");
      sb.writeln("    }");
    }
    sb.writeln("    return map;");
    sb.writeln("  }");

    sb.writeln("");
    sb.writeln("  factory $name.fromJson(Map<String, dynamic> json) {");
    // Strict property validation
    sb.writeln("    final allowedProps = {");
    for (final pId in allAllowedProps) {
       sb.writeln("      '${pId.replaceFirst('schema:', '')}',");
    }
    sb.writeln("      '@type', '@context', '@id'");
    sb.writeln("    };");
    sb.writeln("    for (final key in json.keys) {");
    sb.writeln("      if (!allowedProps.contains(key)) throw Exception('Property \$key is not allowed for type $name');");
    sb.writeln("    }");

    sb.writeln("    final obj = $name();");
    if (enumerations.containsKey(id)) {
       sb.writeln("    if (json is String) { obj.value = json; }");
       sb.writeln("    else if (json['value'] != null) { obj.value = json['value'] as String?; }");
    }
    for (final propId in props) {
      final propName = propId.replaceFirst('schema:', '');
      String fieldName = propName;
      if (reservedNames.contains(fieldName)) fieldName = 'schema$fieldName';
      sb.writeln("    if (json['$propName'] != null) obj.$fieldName = json['$propName'];");
    }
    sb.writeln("    if (json is Map && json['@id'] != null) obj.id = json['@id'] as String?;");
    sb.writeln("    return obj;");
    sb.writeln("  }");
    
    sb.writeln("}");
    sb.writeln("");
  }

  // Schema Validator
  sb.writeln("class SchemaValidator {");
  sb.writeln("  static void validate(Map<String, dynamic> json) {");
  sb.writeln("    final type = json['@type'];");
  sb.writeln("    if (type == null) throw Exception('Missing @type in Schema.org JSON-LD');");
  sb.writeln("    final knownTypes = {");
  for (final id in allTypes.keys) {
    sb.writeln("      '${id.replaceFirst('schema:', '')}',");
  }
  sb.writeln("    };");
  sb.writeln("    if (!knownTypes.contains(type)) throw Exception('Unknown Schema.org type: \$type');");
  sb.writeln("  }");
  sb.writeln("}");
  
  // Custom fromString
  sb.writeln("");
  sb.writeln("SchemaOrgEntity schemaOrgFromString(String jsonString) {");
  sb.writeln("  final decoded = json.decode(jsonString);");
  sb.writeln("  if (decoded is Map<String, dynamic>) {");
  sb.writeln("    SchemaValidator.validate(decoded);");
  sb.writeln("    final type = decoded['@type'];");
  sb.writeln("    switch (type) {");
  for (final id in allTypes.keys) {
    final name = cleanName(id);
    final typeStr = id.replaceFirst('schema:', '');
    sb.writeln("    case '$typeStr': return $name.fromJson(decoded);");
  }
  sb.writeln("      default: throw Exception('Unsupported type: \$type');");
  sb.writeln("    }");
  sb.writeln("  } else {");
  sb.writeln("    throw Exception('Invalid JSON format for Schema.org entity');");
  sb.writeln("  }");
  sb.writeln("}");

  final outFile = File('lib/src/schema.dart');
  outFile.writeAsStringSync(sb.toString());
  print('Generated lib/src/schema.dart');
}
