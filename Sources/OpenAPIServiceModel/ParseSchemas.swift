// Copyright 2019-2022 Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// A copy of the License is located at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
//
// ParseSchemas.swift
// OpenAPIServiceModel
//

import Foundation
import OpenAPIKit30
import ServiceModelEntities
import ServiceModelCodeGeneration
import Yams

internal extension OpenAPIServiceModel {
    static func parseDefinitionSchemas(model: inout OpenAPIServiceModel, enclosingEntityName: inout String,
                                       schema: JSONSchema, modelOverride: ModelOverride?, document: OpenAPI.Document) {
        switch schema.value {
        case .boolean:
            model.fieldDescriptions[enclosingEntityName] = .boolean
        case .integer(let integerFormat, let integerContext):
            if integerFormat.format == .int64 {
                model.fieldDescriptions[enclosingEntityName] = Fields.long(rangeConstraint:
                                                                            NumericRangeConstraint<Int>(minimum: integerContext.minimum?.value,
                                                                                                        maximum: integerContext.maximum?.value,
                                                                                                        exclusiveMinimum: integerContext.minimum?.exclusive ?? false,
                                                                                                        exclusiveMaximum: integerContext.maximum?.exclusive ?? false))
            } else {
                model.fieldDescriptions[enclosingEntityName] = Fields.integer(rangeConstraint:
                                                                            NumericRangeConstraint<Int>(minimum: integerContext.minimum?.value,
                                                                                                        maximum: integerContext.maximum?.value,
                                                                                                        exclusiveMinimum: integerContext.minimum?.exclusive ?? false,
                                                                                                        exclusiveMaximum: integerContext.maximum?.exclusive ?? false))
            }
            
        case .object(_ , let objectContext):
            if case .b(let mapSchema) = objectContext.additionalProperties {
                parseMapDefinitionSchema(mapSchema: mapSchema,
                                         enclosingEntityName: &enclosingEntityName,
                                         model: &model)
            } else {
                var structureDescription = StructureDescription()
                parseObjectSchema(structureDescription: &structureDescription, enclosingEntityName: &enclosingEntityName,
                                  model: &model, objectContext: objectContext, modelOverride: modelOverride, document: document)
                
                model.structureDescriptions[enclosingEntityName] = structureDescription
            }
        case .array(_, let arrayContext):
            parseArrayDefinitionSchemas(arrayMetadata: arrayContext, enclosingEntityName: &enclosingEntityName,
                                        model: &model, modelOverride: modelOverride, document: document)
        case .string(_, let stringContext):
            addStringField(metadata: stringContext, schema: schema,
                           model: &model, fieldName: enclosingEntityName, modelOverride: modelOverride)
        case .number(_, let numberContext):
            model.fieldDescriptions[enclosingEntityName] = Fields.double(rangeConstraint:
                                                                            NumericRangeConstraint<Double>(minimum: numberContext.minimum?.value,
                                                                                                           maximum: numberContext.maximum?.value,
                                                                                                           exclusiveMinimum: numberContext.minimum?.exclusive ?? false,
                                                                                                           exclusiveMaximum: numberContext.maximum?.exclusive ?? false))
        case .all(let otherSchema, _), .any(let otherSchema, _), .one(let otherSchema, _):
            var structureDescription = StructureDescription()
            parseOtherSchemas(structureDescription: &structureDescription, enclosingEntityName: &enclosingEntityName,
                              model: &model, otherSchema: otherSchema, modelOverride: modelOverride, document: document)
        case .reference:
            break
        case .fragment:
            fatalError("Schema 'fragment' not implemented")
        case .not:
            fatalError("Schema 'not' not implemented")
        }
    }
    
    static func parseObjectSchema(structureDescription: inout StructureDescription, enclosingEntityName: inout String,
                                  model: inout OpenAPIServiceModel, objectContext: JSONSchema.ObjectContext,
                                  modelOverride: ModelOverride?, document: OpenAPI.Document) {
        let sortedKeys = objectContext.properties.keys.sorted(by: <)
        
        for (index, name) in sortedKeys.enumerated() {
            guard let property = objectContext.properties[name] else {
                continue
            }
            switch property.value {
            case .reference(let ref, _):
                if let referenceName = ref.name {
                    structureDescription.members[name] = Member(value: referenceName, position: index,
                                                                required: objectContext.requiredProperties.contains(name),
                                                                documentation: nil)
            }
            default:
                var enclosingEntityNameForProperty = enclosingEntityName + name.startingWithUppercase
                parseDefinitionSchemas(model: &model, enclosingEntityName: &enclosingEntityNameForProperty,
                                       schema: property, modelOverride: modelOverride, document: document)
                
                structureDescription.members[name] = Member(value: enclosingEntityNameForProperty, position: index,
                                                            required: objectContext.requiredProperties.contains(name),
                                                            documentation: nil)
            }
        }
    }
    
    static func parseMapDefinitionSchema(mapSchema: JSONSchema,
                                         enclosingEntityName: inout String,
                                         model: inout OpenAPIServiceModel) {
        let valueType: String
        switch mapSchema.value {
        case .reference(let ref, _):
            if let valueType = ref.name {
                model.fieldDescriptions[enclosingEntityName] = Fields.map(
                    keyType: "String", valueType: valueType,
                    lengthConstraint: LengthRangeConstraint<Int>())
            }
        case .string:
            valueType = "String"
            model.fieldDescriptions[enclosingEntityName] = Fields.map(
                keyType: "String", valueType: valueType,
                lengthConstraint: LengthRangeConstraint<Int>())
        default:
            fatalError("Not implemented")
        }
    }
    
    static func parseArrayDefinitionSchemas(arrayMetadata: JSONSchema.ArrayContext,
                                            enclosingEntityName: inout String,
                                            model: inout OpenAPIServiceModel,
                                            modelOverride: ModelOverride?, document: OpenAPI.Document) {
        if let items = arrayMetadata.items {
            switch items.value {
            case .reference(let ref, _):
                if let type = ref.name {
                    let optionalMinItems: Int?
                    if arrayMetadata.minItems > 0 {
                        optionalMinItems = arrayMetadata.minItems
                    } else {
                        optionalMinItems = nil
                    }
                    
                    let lengthConstraint = LengthRangeConstraint<Int>(minimum: optionalMinItems,
                                                                      maximum: arrayMetadata.maxItems)
                    model.fieldDescriptions[enclosingEntityName] = Fields.list(type: type,
                                                                               lengthConstraint: lengthConstraint)
                }
            default:
                var arrayElementEntityName: String
                
                // If the enclosingEntityName ends in an "s", swap with element name
                if enclosingEntityName.suffix(1).lowercased() == "s" {
                    arrayElementEntityName = String(enclosingEntityName.dropLast())
                } else {
                    arrayElementEntityName = enclosingEntityName
                    enclosingEntityName = "\(enclosingEntityName)s"
                }
                
                parseDefinitionSchemas(model: &model, enclosingEntityName: &arrayElementEntityName,
                                       schema: items, modelOverride: modelOverride, document: document)
                
                let type = arrayElementEntityName
                
                let optionalMinItems: Int?
                if arrayMetadata.minItems > 0 {
                    optionalMinItems = arrayMetadata.minItems
                } else {
                    optionalMinItems = nil
                }
                
                let lengthConstraint = LengthRangeConstraint<Int>(minimum: optionalMinItems,
                                                                  maximum: arrayMetadata.maxItems)
                model.fieldDescriptions[enclosingEntityName] = Fields.list(type: type,
                                                                           lengthConstraint: lengthConstraint)
            }
        }
    }
    
    // Parse all, any, one schemas
    static func parseOtherSchemas(structureDescription: inout StructureDescription, enclosingEntityName: inout String,
                                  model: inout OpenAPIServiceModel, otherSchema: [JSONSchema],
                                  modelOverride: ModelOverride?, document: OpenAPI.Document) {
        for (index, subschema) in otherSchema.enumerated() {
            var enclosingEntityNameForProperty = "\(enclosingEntityName)\(index + 1)"
            
            switch subschema.value {
            case .object(_, let objectContext):
                parseObjectSchema(structureDescription: &structureDescription, enclosingEntityName: &enclosingEntityNameForProperty,
                                  model: &model, objectContext: objectContext, modelOverride: modelOverride, document: document)
            default:
                fatalError("Non object/structure allOf schemas are not implemented. \(String(describing: subschema.jsonType))")
            }
        }
    }
}
