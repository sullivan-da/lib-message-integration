-- Copyright (c) 2019 Digital Asset (Switzerland) GmbH and/or its affiliates. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0

-- | Convert the CDM rosetta schema into our generic type model.
--
module DA.CDM.Rosetta.Convert where

import           Control.Applicative   ((<$>))
import           Control.Monad.Logger
import           Control.Monad.Reader
import           DA.CDM.Rosetta.Schema as Rosetta
import           DA.Daml.TypeModel     (PrimType (..), Type (..))
import qualified DA.Daml.TypeModel     as Model
import           Data.List             (foldl')
import           Data.Map              (Map)
import qualified Data.Map              as Map
import qualified Data.Set              as Set
import           Data.Maybe
import           Prelude               hiding (Enum)

type Name = String
type Conv = ReaderT Env (LoggingT IO)

-- | Contain the original name(s) with may differ from the DAML names.
-- Multiple names imply that we expect one of a variety of possible names for
-- this field, e.g. issuer and issuerReference.
data CdmMeta
    = CdmField Name (Maybe Name) -- field name, type
    | CdmEnum  Name
    deriving Show

data Env = Env
   { envClasses :: Map Identifier Class
   , envEnums   :: Map Identifier Enum
   }

instance Monoid Env where
    mempty = Env mempty mempty

instance Semigroup Env where
    (<>) e1 e2 = Env
        { envClasses = Map.union (envClasses e1) (envClasses e2)
        , envEnums   = Map.union (envEnums e1) (envEnums e2)
        }

mkEnv :: Schema -> Env
mkEnv Schema{..} = foldl' decl mempty schemaDecls
  where
    decl :: Env -> Decl -> Env
    decl env (ClassDecl d) = env { envClasses = Map.insert (className d) d (envClasses env) }
    decl env (EnumDecl d)  = env { envEnums = Map.insert (enumName d) d (envEnums env) }
    decl env _             = env

convert :: Name -> Schema -> Conv (Model.Module CdmMeta)
convert name Schema{..} = do
    decls <- concat <$> mapM convDecl schemaDecls
    return Model.Module
        { module_name      = name -- fully qualified, for now ignore namespace in files
        , module_imports   = []
        , module_decls     = decls
        , module_comment   = Model.Comment (Just "Generated by metagen")
        }

convDecl :: Decl -> Conv [Model.Decl CdmMeta]
convDecl (ClassDecl c) = convClass c
convDecl (EnumDecl e)  = convEnum e
convDecl _ = return []

convClass :: Class -> Conv [Model.Decl CdmMeta]
convClass cls = do
    classMap <- asks envClasses
    return
        . (:[])
        . toTypeModel
        . inlineSuper classMap
        . addFields
        $ cls
  where

    -- inline all fields from the super-classes
    inlineSuper :: Map Identifier Class -> Class -> Class
    inlineSuper classMap = inline
      where
        inline c = fromMaybe c $ do
            base <- classBase c
            c' <- inline <$> Map.lookup base classMap
            return $ c { classFields = classFields c' ++ classFields c }

    addFields :: Class -> Class
    addFields cls =
        case unIdentifier (className cls) of
            "Party"               -> addDamlParty cls
            "MessageInformation"  -> addDamlCopyTo cls
            _ | CRosettaKey `Set.member` classMeta cls
                                  -> addRosettaKey cls
              | CRosettaKeyValue `Set.member` classMeta cls
                                  -> addRosettaKeyValue cls
              | otherwise         -> cls
      where
        addDamlParty cls =
            cls { classFields = mkClassField "damlParty" "DamlParty" oneOf : classFields cls }
        addDamlCopyTo cls =
            cls { classFields = mkClassField "damlCopyTo" "DamlParty" listOf : classFields cls }
        addRosettaKey cls =
            cls { classFields = mkClassField "rosettaKey" "string" oneOf : classFields cls }
        addRosettaKeyValue cls =
            cls { classFields = mkClassField "rosettaKeyValue" "string" oneOf : classFields cls }

        mkClassField :: Name -> Name -> Cardinality -> ClassField
        mkClassField name ty card =
            ClassField
                { classFieldName       = Identifier name
                , classFieldType       = Just (Identifier ty)
                , classFieldCard       = card
                , classFieldId         = False
                , classFieldMeta1      = mempty
                , classFieldMeta2      = mempty
                , classFieldAnnotation = Just (Annotation "field added by metagen")
                }

        oneOf = Cardinality 1 (Bounded 1)
        listOf = Cardinality 0 Unbounded
        -- optional = Cardinality 0 (Bounded 1)

    toTypeModel :: Class -> Model.Decl CdmMeta
    toTypeModel Class{..} =
        Model.RecordType name fields comment
      where
        fields  = map convClassField $ filter (not . zeroCard) classFields
        name    = convClassName className
        comment = convAnnotation classAnnotation

        zeroCard :: ClassField -> Bool
        zeroCard cf = classFieldCard cf == Cardinality 0 (Bounded 0)

convClassField :: ClassField -> Model.Field CdmMeta
convClassField ClassField{..} =
    Model.Field
        { field_name        = case () of
              -- _ | FReference       `Set.member` classFieldMeta2
              --               -> convFieldName classFieldName ++ "Reference"
              _ | otherwise -> convFieldName classFieldName
        , field_type        = case () of
              _ | FRosettaKey      `Set.member` classFieldMeta2 ||
                  FRosettaKeyValue `Set.member` classFieldMeta2 ||
                  FReference       `Set.member` classFieldMeta2
                            -> Prim PrimText
                | otherwise -> convType classFieldType
        , field_cardinality = convCardinality classFieldCard
        , field_comment     = convAnnotation classFieldAnnotation
        , field_meta        =
              let name   = unIdentifier classFieldName
                  tyName = unIdentifier <$> classFieldType
              in CdmField name tyName
        }

convEnum :: Enum -> Conv [Model.Decl CdmMeta]
convEnum e = do
    enumMap <- asks envEnums
    return
        . (:[])
        . toTypeModel
        . inlineSuper enumMap
        $ e

  where
    -- inline all enums from the super-enums
    inlineSuper :: Map Identifier Enum -> Enum -> Enum
    inlineSuper enumMap = inline
      where
        inline e = fromMaybe e $ do
            base <- enumBase e
            e' <- inline <$> Map.lookup base enumMap
            return $ e { enumFields = enumFields e' ++ enumFields e }

    toTypeModel :: Enum -> Model.Decl CdmMeta
    toTypeModel Rosetta.Enum{..} =
        Model.EnumType name fields comment
      where
        fields  = map convEnumField enumFields
        name    = unIdentifier enumName
        comment = convAnnotation enumAnnotation

-- TODO use displayName ?
convEnumField :: EnumField -> (Name, CdmMeta, Model.Comment)
convEnumField EnumField{..} =
    ( unIdentifier enumFieldName
    , CdmEnum (unIdentifier enumFieldName)
    , convAnnotation enumFieldAnnotation
    )

convType :: Maybe Identifier -> Type CdmMeta
 -- NB: assume text type for any missing type annotation
convType Nothing    = Prim PrimText
convType (Just idn) =
    case unIdentifier idn of
        "int"           -> Prim PrimInteger
        "number"        -> Prim PrimDecimal
        "boolean"       -> Prim PrimBool
        "string"        -> Prim PrimText
        "date"          -> Prim PrimDate
        "time"          -> Prim PrimText -- DAML has only datetime
        "dateTime"      -> Prim PrimTime
        "zonedDateTime" -> Prim PrimTime
        "calculation"   -> Prim PrimText
        "eventType"     -> Prim PrimText
        "productType"   -> Prim PrimText
        "DamlParty"     -> Prim PrimParty
        _               -> Nominal $ convClassName idn

convCardinality :: Cardinality -> Model.Cardinality
convCardinality (Cardinality lower upper) =
    Model.Cardinality (f lower) (g upper)
  where
    f 0 = Model.Zero
    f _ = Model.One
    g (Bounded 1) = Model.ToOne
    g (Bounded _) = Model.ToMany
    g Unbounded   = Model.ToMany

convAnnotation :: Maybe Annotation -> Model.Comment
convAnnotation = maybe Model.noComment (Model.Comment . Just . unAnnotation)

-- fix clashes with DAML types
convClassName :: Identifier -> String
convClassName idn =
    case unIdentifier idn of
        "Event"         -> "EventData"
        "Contract"      -> "ContractData"
        "Party"         -> "PartyData"
        ty              -> ty

-- fix clash with DAML reserved words
convFieldName :: Identifier -> String
convFieldName (Identifier idn) =
    case idn of
        "type"     -> "typ"
        "exercise" -> "exe"
        s          -> s
