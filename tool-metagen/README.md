# Metagen

## Overview

Metagen is a tool to generate Daml types and Daml type metadata from message format schemas to integrate with the Ledger API. It currently supports XSD schemas, and the metadata produced is used by the encoders and decoders in the [Java Integration Library](../lib-integration-java/README.md) to convert messages to and from a Daml Ledger.

## Prerequisites

- [Cabal](https://www.haskell.org/cabal/)

### Installation on macOS
To install Cabal on macOS:
```
xcode-select --install
brew install cabal-install
```

## Building

```
cabal new-update
cabal new-build
cabal new-run metagen -- [ARGS]
```

## Examples

### FpML

```
cabal new-run metagen -- xsd -s ../lib-integration-java/src/main/resources/fpml/confirmation/fpml-main-5-10.xsd -n Confirmation -o ./target/ -p FpML.V510 -j v510
```

## FAQ

- How does the XSD translation work?

  All type hierarchies are flattened, in order to simplify using the
types from Daml and to get smaller Daml-LF values. Essentially fields
from XSD base types are inlined into the subtypes by the conversion
process. Sequences become records and choices / substitution groups
become variants. We have taken the decision not to use structural
types such as tuples and Either/EitherN, as these lose the field
names. This does result in some non-descriptive machine generated type
names, but they typically do have informative field names and
comments.
