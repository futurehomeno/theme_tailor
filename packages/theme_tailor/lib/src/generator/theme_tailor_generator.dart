import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/visitor.dart';
import 'package:collection/collection.dart';
import 'package:source_gen/source_gen.dart';
import 'package:theme_tailor/src/generator/generator_for_annotated_class.dart';
import 'package:theme_tailor/src/model/annotation_data_manager.dart';
import 'package:theme_tailor/src/model/field.dart';
import 'package:theme_tailor/src/model/library_data.dart';
import 'package:theme_tailor/src/model/tailor_annotation_data.dart';
import 'package:theme_tailor/src/model/theme_class_config.dart';
import 'package:theme_tailor/src/model/theme_encoder_data.dart';
import 'package:theme_tailor/src/model/theme_getter_data.dart';
import 'package:theme_tailor/src/template/context_extension_template.dart';
import 'package:theme_tailor/src/template/template.dart';
import 'package:theme_tailor/src/template/theme_class_template.dart';
import 'package:theme_tailor/src/util/extension/contant_reader_extension.dart';
import 'package:theme_tailor/src/util/extension/dart_type_extension.dart';
import 'package:theme_tailor/src/util/extension/element_annotation_extension.dart';
import 'package:theme_tailor/src/util/extension/element_extension.dart';
import 'package:theme_tailor/src/util/extension/field_declaration_extension.dart';
import 'package:theme_tailor/src/util/extension/library_element_extension.dart';
import 'package:theme_tailor/src/util/field_helper.dart';
import 'package:theme_tailor/src/util/string_format.dart';
import 'package:theme_tailor/src/util/theme_encoder_helper.dart';
import 'package:theme_tailor_annotation/theme_tailor_annotation.dart';

class TailorGenerator extends GeneratorForAnnotatedClass<ImportsData, TailorAnnotationData, ThemeClassConfig, Tailor> {
  const TailorGenerator(this.buildYamlConfig);

  final Tailor buildYamlConfig;

  @override
  ClassElement ensureClassElement(Element element) {
    if (element is ClassElement && element is! Enum) return element;

    throw InvalidGenerationSourceError(
      'Tailor can only annotate classes',
      element: element,
      todo: 'Move @Tailor annotation above `class`',
    );
  }

  @override
  ImportsData parseLibraryData(LibraryElement library, ClassElement element) {
    return ImportsData(
      hasJsonSerializable: element.hasJsonSerializableAnnotation,
      hasDiagnosticableMixin: library.hasFlutterDiagnosticableImport,
    );
  }

  @override
  TailorAnnotationData parseAnnotation(ConstantReader annotation) {
    return TailorAnnotationData(
      themes: annotation.getFieldOrElse(
        'themes',
        decode: (o) => o.toStringList(),
        orElse: () => buildYamlConfig.themes ?? ['light', 'dark'],
      ),
      themeGetter: annotation.getFieldOrElse(
        'themeGetter',
        decode: (o) => ThemeGetter.values.byName(o.revive().accessor.split('.').last),
        orElse: () => buildYamlConfig.themeGetter ?? ThemeGetter.onBuildContextProps,
      ),
      requireStaticConst: annotation.getFieldOrElse(
        'requireStaticConst',
        decode: (o) => o.boolValue,
        orElse: () => buildYamlConfig.requireStaticConst ?? false,
      ),
      generateStaticGetters: annotation.getFieldOrElse(
        'generateStaticGetters',
        decode: (o) => o.boolValue,
        orElse: () => buildYamlConfig.generateStaticGetters ?? false,
      ),
      encoders: _typeToThemeEncoderDataFromAnnotation(annotation),
    );
  }

  @override
  ThemeClassConfig parseData(
    ImportsData libraryData,
    TailorAnnotationData annotationData,
    ClassElement element,
  ) {
    const fmt = StringFormat();
    final classLevelEncoders = annotationData.encoders;
    final classLevelAnnotations = <String>[];
    final fieldLevelAnnotations = <String, List<String>>{};

    final tailorClassVisitor = _TailorClassVisitor(
      requireConstThemes: annotationData.requireStaticConst,
      generateStaticGetters: annotationData.generateStaticGetters,
    );
    element.visitChildren(tailorClassVisitor);

    final fields = tailorClassVisitor.fields;

    final astVisitor = _TailorClassASTVisitor();
    final classAstNode = _getAstNodeFromElement(element);
    classAstNode.visitChildren(astVisitor);

    for (final typeEntry in astVisitor.fieldTypes.entries) {
      fields[typeEntry.key]?.type = typeEntry.value;
    }

    for (final field in fields.entries) {
      field.value.values = List.generate(
        annotationData.themes.length,
        (index) {
          return '${element.name}.${field.key}[$index]';
        },
      );
    }

    for (var i = 0; i < element.metadata.length; i++) {
      final annotation = element.metadata[i];

      final encoder = extractThemeEncoderData(
        annotation,
        annotation.computeConstantValue()!,
      );

      if (encoder != null) {
        classLevelEncoders[encoder.type] = encoder;
        continue;
      }

      if (!annotation.isTailorAnnotation && !annotation.isSourceGenAnnotation) {
        classLevelAnnotations.add(astVisitor.rawClassAnnotations[i]);
      }
    }

    for (var entry in tailorClassVisitor.hasInternalAnnotations.entries) {
      if (entry.value.isEmpty) continue;

      final astAnnotations = <String>[];

      entry.value.forEachIndexed((i, isInternal) {
        if (!isInternal) {
          astAnnotations.add(astVisitor.rawFieldsAnnotations[entry.key]![i]);
        }
      });

      fieldLevelAnnotations[entry.key] = astAnnotations;
    }

    final sortedFields = Map.fromEntries(
      tailorClassVisitor.fields.entries.sorted(
        (a, b) => a.value.compareTo(b.value),
      ),
    );

    final themeFieldName = getFreeFieldName(
      fieldNames: fields.keys.toList(),
      proposedNames: ['themes', 'tailorThemes', 'tailorThemesList'],
      warningPropertyName: 'tailor theme list',
    );

    return ThemeClassConfig(
      fields: sortedFields,
      className: fmt.themeClassName(element.name),
      baseClassName: element.name,
      themes: annotationData.themes,
      themesFieldName: themeFieldName,
      encoderManager: ThemeEncoderManager(
        classLevelEncoders,
        tailorClassVisitor.fieldLevelEncoders,
      ),
      themeGetter: annotationData.themeGetter.extensionData,
      annotationManager: AnnotationDataManager(
        classAnnotations: classLevelAnnotations,
        fieldsAnotations: fieldLevelAnnotations,
      ),
      hasDiagnosticableMixin: libraryData.hasDiagnosticableMixin,
      hasJsonSerializable: libraryData.hasJsonSerializable,
      constantThemes: false,
      staticGetters: annotationData.generateStaticGetters,
    );
  }

  @override
  void generateForData(StringBuffer buffer, ThemeClassConfig data) => buffer
    ..template(ThemeTailorTemplate(data, StringFormat()))
    ..template(ContextExtensionTemplate(
      data.className,
      data.themeGetter,
      data.fields.values.toList(),
    ));

  Map<String, ThemeEncoderData> _typeToThemeEncoderDataFromAnnotation(
    ConstantReader annotation,
  ) {
    return annotation.getFieldOrElse(
      'encoders',
      decode: (o) => Map.fromEntries(
        o.listValue
            .map((dartObject) => extractThemeEncoderData(null, dartObject))
            .whereType<ThemeEncoderData>()
            .map((encoderData) => MapEntry(encoderData.type, encoderData)),
      ),
      orElse: () => {},
    );
  }
}

class _TailorClassVisitor extends SimpleElementVisitor {
  _TailorClassVisitor({
    required this.requireConstThemes,
    required this.generateStaticGetters,
  });

  final bool requireConstThemes;
  final bool generateStaticGetters;

  final Map<String, TailorField> fields = {};
  final Map<String, ThemeEncoderData> fieldLevelEncoders = {};
  final Map<String, List<bool>> hasInternalAnnotations = {};
  var hasNonConstantElement = false;

  final extensionAnnotationTypeChecker = TypeChecker.fromRuntime(themeExtension.runtimeType);

  final ignoreAnnotationTypeChecker = TypeChecker.fromRuntime(ignore.runtimeType);

  @override
  void visitFieldElement(FieldElement element) {
    if (ignoreAnnotationTypeChecker.hasAnnotationOf(element)) return;

    if (element.isStatic && element.type.isDartCoreList) {
      if (!requireConstThemes && generateStaticGetters) {
        if (!element.isSynthetic && !element.isConst) {
          print(
            'Field "${element.name}" will not be updated on hot reload, since it is neither a getter nor a const.',
          );
        }
      }

      if (!element.isConst) {
        hasNonConstantElement = true;

        if (requireConstThemes) {
          throw InvalidGenerationSourceError(
            'Field "${element.name}" needs to be a const in order to be included',
            element: element,
            todo: 'Move this field const',
          );
        }
      }

      final propName = element.name;
      final isInternalAnnotation = <bool>[];

      var hasThemeExtensionAnnotation = false;

      for (final annotation in element.metadata) {
        if (annotation.isTailorThemeExtension) {
          isInternalAnnotation.add(true);
          hasThemeExtensionAnnotation = true;
          continue;
        }

        final encoderData = extractThemeEncoderData(
          annotation,
          annotation.computeConstantValue()!,
        );

        if (encoderData != null) {
          isInternalAnnotation.add(true);
          fieldLevelEncoders[propName] = encoderData;
        } else {
          isInternalAnnotation.add(false);
        }
      }

      final coreType = element.type.coreIterableGenericType;

      final implementsThemeExtension = hasThemeExtensionAnnotation || coreType.isThemeExtensionType;

      hasInternalAnnotations[propName] = isInternalAnnotation;

      fields[propName] = TailorField(
        name: propName,
        isThemeExtension: implementsThemeExtension,
        isTailorThemeExtension: hasThemeExtensionAnnotation,
        documentation: element.documentationComment,
      );
    }
  }
}

class _TailorClassASTVisitor extends SimpleAstVisitor {
  _TailorClassASTVisitor();

  final List<String> rawClassAnnotations = [];
  final Map<String, List<String>> rawFieldsAnnotations = {};

  final Map<String, String> fieldTypes = {};

  @override
  void visitAnnotation(Annotation node) {
    rawClassAnnotations.add(node.toString());
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    final fieldName = node.name;
    final fieldType = node.fields.type;

    rawFieldsAnnotations[fieldName] = node.annotations;

    if (fieldType != null) {
      final childTypeEntities = (fieldType.childEntities).map((e) => e.toString()).toList();
      if (childTypeEntities.length >= 2 && childTypeEntities[0] == 'List') {
        final typeWithBraces = childTypeEntities[1];
        fieldTypes[fieldName] = typeWithBraces.substring(1, typeWithBraces.length - 1);
      }
    }
  }
}

AstNode _getAstNodeFromElement(Element element) {
  final result = _getParsedLibraryResultFromElement(element);
  return result!.getElementDeclaration(element)!.node;
}

ParsedLibraryResult? _getParsedLibraryResultFromElement(Element element) {
  final library = element.library;
  final parsedLibrary = library?.session.getParsedLibraryByElement(library);
  if (parsedLibrary is ParsedLibraryResult) {
    return parsedLibrary;
  } else {
    return null;
  }
}
