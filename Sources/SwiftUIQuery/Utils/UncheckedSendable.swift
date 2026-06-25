//
//  UncheckedSendable.swift
//  SwiftUIQuery
//
//  Created by Adam Zethraeus on 2025-12-08.
//



@propertyWrapper
@usableFromInline
struct UncheckedSendable<Value>: @unchecked Sendable {
  @usableFromInline
  var wrappedValue: Value
  init(wrappedValue value: Value) {
    self.wrappedValue = value
  }
}
