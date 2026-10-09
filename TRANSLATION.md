# Translation and compilation status

Snapshot: 2026-09-04. Pinned upstream source:
`b10fa6e93c0206cc0dc8f7abba98534e3edac248`.

Status 2026-10-07: the first milestone is reached. The translated batch
compiler (`haxe.Main`) emits HXB byte-identical to the pinned reference for
all 275 accepted conformance cases, and rejects the 7 cases the reference
rejects; see `test/TESTING.md`. Since the snapshot below, `hxbWriter.ml`,
`grammar.ml` and `lexer.ml` were retranslated directly
(`src/compiler/hxb/HxbWriter.hx`, `src/syntax/Grammar.hx`,
`src/syntax/Lexer.hx`), and the batch entry in `haxe.ml` became
`src/haxe/Main.hx`. The earlier hand-written versions remain as
`LegacyGrammar`, `LegacyLexer` and `LegacyMain`, used only by the bootstrap
unit tests.

Status 2026-10-08: macro execution works. `macro/eval/*.ml` and `macroApi.ml`
are translated in `src/macros/` and `typing/macroContext.ml` in
`src/typing/MacroContext.hx`. All 66 macro-context conformance cases are
byte-identical. The debugger (`evalDebug*.ml`), libuv (`evalLuv.ml`) and mbedtls
(`evalSsl.ml`, except its enum constants) are not ported; see
`src/macros/PORTING.md`. The table below still lists them as macro-milestone
candidates.

Status 2026-10-09: HXB library input (`--hxb-lib`) works. `hxbReader.ml`,
`hxbReaderApi.ml` and `hxbLib.ml` are translated in `src/compiler/hxb/`,
`typeloadCacheHook.ml` in `src/typing/TypeloadCacheHook.hx`, the HXB branch of
`nativeLibraryHandler.ml` in `src/context/NativeLibraryHandler.hx`, and the
`hxb_reader_api_typeload` class and `load_hxb_module` of `typeloadModule.ml` in
`src/typing/ModuleTyping.hx`. The ZIP reading that `hxbLib.ml` takes from
`libs/ziplib` is reproduced in `src/core/ZipInput.hx`. Of `commonCache.ml`,
only the server cache uses the reader (`HxbReader.dump_stats` in
`cache_context`), so nothing of it is needed by the batch `--hxb-lib` path.
See `test/TESTING.md`.

Status 2026-10-09: the compilation server, its caches and haxelib integration
are translated: `compiler/server/*.ml` in `src/compiler/server/`,
`compilationCache.ml`, `pipeThings.ml` and `tasks.ml` in `src/compiler/`,
`context/commonCache.ml` and `typing/typeloadCacheHook.ml`, the client and
server entry of `haxe.ml` (`--connect`, `--wait`, `--server-connect`) in
`src/haxe/Main.hx`, and `add_libs` (`-L`/`--library`, which runs `haxelib
path`) with the `Expand` markers of `args.ml` in `src/compiler/HighLevel.hx`.
As upstream, the batch compiler also runs through `Server.setup_server_context`
and the cache hooks. The server's HXB module cache restores modules with the
translated HXB reader (`HxbReaderApiServer` implements `HxbReaderApi`), and
`-D disable-hxb-cache` keeps typed modules in memory instead. The pinned upstream no longer implements `--wait stdio` (it reports "Invalid
host/port"); the port behaves the same. The host socket API is IPv4 only. See
`test/TESTING.md` for the server and haxelib results.

Status 2026-10-09: display services work in batch mode. `--display` takes a
JSON-RPC request like the pinned reference (the legacy `file@pos` form is a
JSON-RPC parse error upstream too). `typerDisplay.ml`, `context/display/*`,
`displayOutput.ml`, `displayProcessing.ml`, `completionItem.ml`, `genjson.ml`,
`jsonRpc.ml`, `jsonrpc_handler.ml`, are translated, and every display hook in the typer calls them directly
(`context/DeferredServices.hx` is gone). OCaml `Hashtbl` iteration order,
which display output exposes, is reproduced by `core.ds.OcamlHash`
(`caml_hash`) with `core.ds.OcamlHashtbl`. Results of the display corpus are
in `test/TESTING.md`.

## Translation snapshot

**The pending counterpart batch was completed in `2fcd217`.** This inventory records file coverage,
not compilation or behavioral correctness. No builds or tests were run for the translation-first
batches. The bootstrap entry point still uses its existing loader; the new
compiler pipeline is included separately by `compile-all.hxml`.

- 126 new draft/support Haxe files across the translation-first batches.
- 124 upstream ML files have new draft counterparts.
- 33 upstream ML files have pre-existing counterparts; completeness is unaudited.
- 0 additional candidate ML files have no corresponding HX file yet.

This follow-up added 59 in-scope counterparts from the previous 69 pending
candidates. The other ten are explicitly deferred below. `HighLevel` now also
implements haxelib `add_libs` (2026-10-09).

The candidate list is deliberately conservative, not a proven minimal dependency
closure. Translate the source-only HXB path, including its shared filtering and
typing helpers; exclude unrelated service/runtime implementations. Shared types
and batch-used helpers inside otherwise deferred areas still need extraction
when required. An existing counterpart may combine several upstream modules or
implement only a subset: file presence does not close that work.

## Compilation work

The compile phase reconciles enum/record layouts, callback signatures, persistent
maps, typed exceptions, and Haxe secondary-type imports. New runtime adapters
provide OCaml-style lists/maps/tables, fixed-width integer parsing, streams, and
thread scheduling. `Record.withFields` preserves shallow record updates.
`TaskPool` uses bounded host threads per operation instead of a persistent
work-stealing pool; `CompilerIo` uses byte queues instead of OCaml Unix pipes.

Shared HXB-path helpers were extracted from otherwise deferred areas:

- `context/display/DeprecationCheck.hx`: compiler deprecation warnings.
- `context/display/ImportHandling.hx`: imports, aliases, wildcard imports, using
  resolution, and bookkeeping, including the display branches.
- `core/display/DisplayPosition.hx` and `Javadoc.hx`: shared positions and
  documentation parsing required by typing.
- `codegen/Genxml.hx`: RTTI type serialization before HXB save; the standalone
  XML output backend remains deferred.
- `context/HxbReaderStats.hx`: shared statistics declarations, without HXB input.
- `typing/ModuleTyping.hx` and `SourceParser.hx`: source-backed module creation,
  loading, package rules/remapping, import.hx processing, and parser integration
  required by `TyperEntry`; the existing bootstrap loader remains separate.

Display, server, macro-runtime, native-library, and other target dispatch bodies
remain under `deferred/` outside the build classpath. Their call sites reject
unsupported services explicitly. In-scope typing and filtering paths remain in
the all-module build. Compilation does not establish runtime correctness,
conformance, or completion of the pre-existing HXB writer. The subsequent runtime test phase is tracked in
`test/TESTING.md`.

## Draft conventions and reconciliation

- Each new source translation names its upstream file and is marked unvalidated.
- OCaml tuples/records become Haxe records, lists become arrays, and modules become classes or secondary types.
- Drafts may use different unresolved API/type names, ordered-map adapters, exception representations, and callback conventions. Reconcile these in the later compile phase.
- Some exception catches use `Dynamic`; exception-type alignment, OCaml atomics, identity/projections, and persistent-map operations remain for reconciliation.
- Macro/display/native hooks retained in shared modules do not implement those deferred runtimes.
- Ordered source traversals remain explicit in the translations; pool identity and serialization ordering still require conformance validation later.
- Pre-existing `TypeloadModule`, parser and bootstrap paths are not automatically full one-to-one translations. Audit their source coverage before closing the pass.

## Candidate source coverage

| Upstream under `haxe/src/` | Haxe counterpart | Status |
| --- | --- | --- |
| `codegen/codegen.ml` | `src/codegen/Codegen.hx` | Draft translated |
| `codegen/dump.ml` | `src/codegen/Dump.hx` | Draft translated |
| `codegen/fixOverrides.ml` | `src/codegen/FixOverrides.hx` | Draft translated |
| `codegen/overloads.ml` | `src/codegen/Overloads.hx` | Draft translated |
| `compiler/args.ml` | `src/compiler/Args.hx` | Existing, unaudited |
| `compiler/compiler.ml` | `src/compiler/Compiler.hx` | Draft translated |
| `compiler/generate.ml` | `src/compiler/Generate.hx` | Draft translated |
| `compiler/haxe.ml` | `src/haxe/Main.hx` | Translated, including client/server entry |
| `compiler/helper.ml` | `src/compiler/Helper.hx` | Existing, unaudited |
| `compiler/highLevel.ml` | `src/compiler/HighLevel.hx` | Translated, including haxelib `add_libs` |
| `compiler/hxb/hxbData.ml` | `src/compiler/hxb/HxbData.hx` | Existing, unaudited |
| `compiler/hxb/hxbLib.ml` | `src/compiler/hxb/HxbLib.hx` | Translated; ZIP reading in `src/core/ZipInput.hx` (from `libs/ziplib/zip.ml`) |
| `compiler/hxb/hxbReader.ml` | `src/compiler/hxb/HxbReader.hx` | Translated; `hxb_reader_stats` stays in `src/context/HxbReaderStats.hx` |
| `compiler/hxb/hxbReaderApi.ml` | `src/compiler/hxb/HxbReaderApi.hx` | Translated (virtual class as interface) |
| `compiler/hxb/hxbWriter.ml` | `src/compiler/hxb/HxbWriter.hx` | Existing, unaudited |
| `compiler/hxb/hxbWriterConfig.ml` | `src/compiler/hxb/HxbWriterConfig.hx` | Existing, unaudited |
| `compiler/io/compilerIo.ml` | `src/compiler/io/CompilerIo.hx` | Draft translated |
| `compiler/io/compilerMessage.ml` | `src/compiler/io/CompilerMessage.hx` | Draft translated |
| `compiler/io/compilerOutput.ml` | `src/compiler/io/CompilerOutput.hx` | Draft translated |
| `compiler/messageReporting.ml` | `src/compiler/MessageReporting.hx` | Draft translated |
| `compiler/parsedArg.ml` | `src/compiler/ParsedArg.hx` | Existing, unaudited |
| `context/abstractCast.ml` | `src/context/AbstractCast.hx` | Draft translated |
| `context/common.ml` | `src/context/Common.hx` | Draft translated |
| `context/coreApiConfig.ml` | `src/context/CoreApiConfig.hx` | Draft translated |
| `context/dotGraph.ml` | `src/context/DotGraph.hx` | Draft translated |
| `context/dumpConfig.ml` | `src/context/DumpConfig.hx` | Draft translated |
| `context/formatString.ml` | `src/context/FormatString.hx` | Draft translated |
| `context/lookup.ml` | `src/context/Lookup.hx` | Draft translated |
| `context/nativeLibraryHandler.ml` | `src/context/NativeLibraryHandler.hx` | HXB library branch; SWF/JVM libraries rejected explicitly |
| `context/nativeLibraries.ml` | `src/context/NativeLibraries.hx` | Draft translated |
| `context/parallel.ml` | `src/context/Parallel.hx` | Draft translated |
| `context/platformConfig.ml` | `src/context/PlatformConfig.hx` | Draft translated |
| `context/purityState.ml` | `src/context/PurityState.hx` | Draft translated |
| `context/resolution.ml` | `src/context/Resolution.hx` | Draft translated |
| `context/safeCom.ml` | `src/context/SafeCom.hx` | Draft translated |
| `context/typecore.ml` | `src/context/Typecore.hx` | Draft translated |
| `context/typerPass.ml` | `src/context/TyperPass.hx` | Draft translated |
| `core/abstract.ml` | `src/core/Abstract.hx` | Draft translated |
| `core/ast.ml` | `src/core/Ast.hx` | Existing, unaudited |
| `core/classPath.ml` | `src/core/ClassPath.hx` | Existing, unaudited |
| `core/classPaths.ml` | `src/core/ClassPaths.hx` | Existing, unaudited |
| `core/data/dataReaderApi.ml` | `src/core/data/DataReaderApi.hx` | Draft translated |
| `core/data/dataWriterApi.ml` | `src/core/data/DataWriterApi.hx` | Draft translated |
| `core/data/jsonDataApi.ml` | `src/core/data/JsonDataApi.hx` | Existing, unaudited |
| `core/data/metaDataApi.ml` | `src/core/data/MetaDataApi.hx` | Draft translated |
| `core/define.ml` | `src/core/Define.hx` | Existing, unaudited |
| `core/displayTypes.ml` | `src/core/DisplayTypes.hx` | Draft translated |
| `core/ds/atomicLazy.ml` | `src/core/ds/AtomicLazy.hx` | Existing, unaudited |
| `core/ds/nowOrLater.ml` | `src/core/ds/NowOrLater.hx` | Existing, unaudited |
| `core/ds/priorityQueue.ml` | `src/core/ds/PriorityQueue.hx` | Existing, unaudited |
| `core/ds/ring.ml` | `src/core/ds/Ring.hx` | Existing, unaudited |
| `core/ds/stringDynArray.ml` | `src/core/ds/StringDynArray.hx` | Existing, unaudited |
| `core/ds/stringPool.ml` | `src/core/ds/StringPool.hx` | Existing, unaudited |
| `core/ds/threadSafeHashtbl.ml` | `src/core/ds/ThreadSafeHashtbl.hx` | Existing, unaudited |
| `core/error.ml` | `src/core/Error.hx` | Draft translated |
| `core/globals.ml` | `src/core/Globals.hx` | Existing, unaudited |
| `core/inheritDoc.ml` | `src/core/InheritDoc.hx` | Draft translated |
| `core/message.ml` | `src/core/Message.hx` | Existing, unaudited |
| `core/meta.ml` | `src/core/Meta.hx` | Draft translated |
| `core/naming.ml` | `src/core/Naming.hx` | Draft translated |
| `core/native.ml` | `src/core/Native.hx` | Draft translated |
| `core/numeric.ml` | `src/core/Numeric.hx` | Existing, unaudited |
| `core/path.ml` | `src/core/Path.hx` | Existing, unaudited |
| `core/socket.ml` | `src/core/Socket.hx` | Existing, unaudited |
| `core/stringError.ml` | `src/core/StringError.hx` | Existing, unaudited |
| `core/stringHelper.ml` | `src/core/StringHelper.hx` | Existing, unaudited |
| `core/tFunctions.ml` | `src/core/TFunctions.hx` | Draft translated |
| `core/tOther.ml` | `src/core/TOther.hx` | Draft translated |
| `core/tPrinting.ml` | `src/core/TPrinting.hx` | Draft translated |
| `core/tType.ml` | `src/core/TType.hx` | Existing, unaudited |
| `core/tUnification.ml` | `src/core/TUnification.hx` | Draft translated |
| `core/texpr.ml` | `src/core/Texpr.hx` | Draft translated |
| `core/timer.ml` | `src/core/Timer.hx` | Draft translated |
| `core/type.ml` | `src/core/Type.hx` | Draft translated |
| `core/warning.ml` | `src/core/Warning.hx` | Draft translated |
| `core/withType.ml` | `src/core/WithType.hx` | Draft translated |
| `core/zip_output.ml` | `src/core/ZipOutput.hx` | Existing, unaudited |
| `coro/contTypes.ml` | `src/coro/ContTypes.hx` | Draft translated |
| `coro/coro.ml` | `src/coro/Coro.hx` | Draft translated |
| `coro/coroConfig.ml` | `src/coro/CoroConfig.hx` | Draft translated |
| `coro/coroControl.ml` | `src/coro/CoroControl.hx` | Draft translated |
| `coro/coroDebug.ml` | `src/coro/CoroDebug.hx` | Draft translated |
| `coro/coroElsewhere.ml` | `src/coro/CoroElsewhere.hx` | Draft translated |
| `coro/coroFromTexpr.ml` | `src/coro/CoroFromTexpr.hx` | Draft translated |
| `coro/coroFunctions.ml` | `src/coro/CoroFunctions.hx` | Draft translated |
| `coro/coroInit.ml` | `src/coro/CoroInit.hx` | Draft translated |
| `coro/coroScopeConfig.ml` | `src/coro/CoroScopeConfig.hx` | Draft translated |
| `coro/coroToTexpr.ml` | `src/coro/CoroToTexpr.hx` | Draft translated |
| `coro/coroTypes.ml` | `src/coro/CoroTypes.hx` | Draft translated |
| `filters/exception/exceptionFunctions.ml` | `src/filters/exception/ExceptionFunctions.hx` | Draft translated |
| `filters/exception/exceptionInit.ml` | `src/filters/exception/ExceptionInit.hx` | Draft translated |
| `filters/exception/exceptions.ml` | `src/filters/exception/Exceptions.hx` | Draft translated |
| `filters/exception/saveStacks.ml` | `src/filters/exception/SaveStacks.hx` | Draft translated |
| `filters/filterContext.ml` | `src/filters/FilterContext.hx` | Draft translated |
| `filters/filters.ml` | `src/filters/Filters.hx` | Draft translated |
| `filters/filtersCommon.ml` | `src/filters/FiltersCommon.hx` | Draft translated |
| `filters/localUsage.ml` | `src/filters/LocalUsage.hx` | Draft translated |
| `filters/renameVars.ml` | `src/filters/RenameVars.hx` | Draft translated |
| `filters/safe/addFieldInits.ml` | `src/filters/safe/AddFieldInits.hx` | Draft translated |
| `filters/safe/addFinalReturn.ml` | `src/filters/safe/AddFinalReturn.hx` | Draft translated |
| `filters/safe/capturedVars.ml` | `src/filters/safe/CapturedVars.hx` | Draft translated |
| `filters/safe/checkVarInit.ml` | `src/filters/safe/CheckVarInit.hx` | Draft translated |
| `filters/safe/localStatic.ml` | `src/filters/safe/LocalStatic.hx` | Draft translated |
| `filters/safe/safeFilters.ml` | `src/filters/safe/SafeFilters.hx` | Draft translated |
| `filters/safe/sanitize.ml` | `src/filters/safe/Sanitize.hx` | Draft translated |
| `filters/tre.ml` | `src/filters/Tre.hx` | Draft translated |
| `optimization/analyzer.ml` | `src/optimization/Analyzer.hx` | Draft translated |
| `optimization/analyzerConfig.ml` | `src/optimization/AnalyzerConfig.hx` | Draft translated |
| `optimization/analyzerTexpr.ml` | `src/optimization/AnalyzerTexpr.hx` | Draft translated |
| `optimization/analyzerTexprTransformer.ml` | `src/optimization/AnalyzerTexprTransformer.hx` | Draft translated |
| `optimization/analyzerTypes.ml` | `src/optimization/AnalyzerTypes.hx` | Draft translated |
| `optimization/dce.ml` | `src/optimization/Dce.hx` | Draft translated |
| `optimization/inline.ml` | `src/optimization/Inline.hx` | Draft translated |
| `optimization/inlineConstructors.ml` | `src/optimization/InlineConstructors.hx` | Draft translated |
| `optimization/optimizer.ml` | `src/optimization/Optimizer.hx` | Draft translated |
| `optimization/optimizerTexpr.ml` | `src/optimization/OptimizerTexpr.hx` | Draft translated |
| `syntax/grammar.ml` | `src/syntax/Grammar.hx` | Existing, unaudited |
| `syntax/lexer.ml` | `src/syntax/Lexer.hx` | Existing, unaudited |
| `syntax/parser.ml` | `src/syntax/Parser.hx` | Draft translated |
| `syntax/parserConfig.ml` | `src/syntax/ParserConfig.hx` | Draft translated |
| `syntax/parserEntry.ml` | `src/syntax/ParserEntry.hx` | Draft translated |
| `syntax/reification.ml` | `src/syntax/Reification.hx` | Draft translated |
| `syntax/semver.ml` | `src/syntax/SemVer.hx` | Existing, unaudited |
| `typing/callUnification.ml` | `src/typing/CallUnification.hx` | Draft translated |
| `typing/calls.ml` | `src/typing/Calls.hx` | Draft translated |
| `typing/fieldAccess.ml` | `src/typing/FieldAccess.hx` | Draft translated |
| `typing/fieldCallCandidate.ml` | `src/typing/FieldCallCandidate.hx` | Draft translated |
| `typing/fields.ml` | `src/typing/Fields.hx` | Draft translated |
| `typing/finalization.ml` | `src/typing/Finalization.hx` | Draft translated |
| `typing/forLoop.ml` | `src/typing/ForLoop.hx` | Draft translated |
| `typing/functionArguments.ml` | `src/typing/FunctionArguments.hx` | Draft translated |
| `typing/generic.ml` | `src/typing/Generic.hx` | Draft translated |
| `typing/instanceBuilder.ml` | `src/typing/InstanceBuilder.hx` | Draft translated |
| `typing/matcher/bind.ml` | `src/typing/matcher/Bind.hx` | Draft translated |
| `typing/matcher/case.ml` | `src/typing/matcher/Case.hx` | Draft translated |
| `typing/matcher/compile.ml` | `src/typing/matcher/Compile.hx` | Draft translated |
| `typing/matcher/constructor.ml` | `src/typing/matcher/Constructor.hx` | Draft translated |
| `typing/matcher/decisionTree.ml` | `src/typing/matcher/DecisionTree.hx` | Draft translated |
| `typing/matcher/exprToPattern.ml` | `src/typing/matcher/ExprToPattern.hx` | Draft translated |
| `typing/matcher/matcherGlobals.ml` | `src/typing/matcher/MatcherGlobals.hx` | Draft translated |
| `typing/matcher/pattern.ml` | `src/typing/matcher/Pattern.hx` | Draft translated |
| `typing/matcher/subject.ml` | `src/typing/matcher/Subject.hx` | Draft translated |
| `typing/matcher/texprConverter.ml` | `src/typing/matcher/TexprConverter.hx` | Draft translated |
| `typing/matcher/useless.ml` | `src/typing/matcher/Useless.hx` | Draft translated |
| `typing/matcher.ml` | `src/typing/Matcher.hx` | Draft translated |
| `typing/nullSafety.ml` | `src/typing/NullSafety.hx` | Draft translated |
| `typing/operators.ml` | `src/typing/Operators.hx` | Draft translated |
| `typing/overloadResolution.ml` | `src/typing/OverloadResolution.hx` | Draft translated |
| `typing/strictMeta.ml` | `src/typing/StrictMeta.hx` | Draft translated |
| `typing/tanon_identification.ml` | `src/typing/TanonIdentification.hx` | Draft translated |
| `typing/typeload.ml` | `src/typing/Typeload.hx` | Draft translated |
| `typing/typeloadCacheHook.ml` | `src/typing/TypeloadCacheHook.hx` | Translated (also used by `MacroContext` for fake modules) |
| `typing/typeloadCheck.ml` | `src/typing/TypeloadCheck.hx` | Draft translated |
| `typing/typeloadFields.ml` | `src/typing/TypeloadFields.hx` | Draft translated |
| `typing/typeloadFunction.ml` | `src/typing/TypeloadFunction.hx` | Draft translated |
| `typing/typeloadModule.ml` | `src/typing/ModuleTyping.hx`; legacy `TypeloadModule.hx` | Source pipeline integrated during compile phase; `hxb_reader_api_typeload` and `load_hxb_module` translated |
| `typing/typeloadParse.ml` | `src/typing/SourceParser.hx`; legacy `TypeloadParse.hx` | Source pipeline integrated during compile phase |
| `typing/typer.ml` | `src/typing/Typer.hx` | Draft translated |
| `typing/typerBase.ml` | `src/typing/TyperBase.hx` | Draft translated |
| `typing/typerDotPath.ml` | `src/typing/TyperDotPath.hx` | Draft translated |
| `typing/typerEntry.ml` | `src/typing/TyperEntry.hx` | Draft translated |
| `typing/unifyMin.ml` | `src/typing/UnifyMin.hx` | Draft translated |

## Additional shared source coverage

| Upstream under `haxe/src/` | Haxe counterpart | Scope |
| --- | --- | --- |
| `context/display/deprecationCheck.ml` | `src/context/display/DeprecationCheck.hx` | Compiler warnings |
| `context/display/importHandling.ml` | `src/context/display/ImportHandling.hx` | Batch imports and using resolution |
| `core/display/displayPosition.ml` | `src/core/display/DisplayPosition.hx` | Shared position state |
| `core/display/javadoc.ml` | `src/core/display/Javadoc.hx` | Documentation parsing |
| `codegen/genxml.ml` | `src/codegen/Genxml.hx` | RTTI serializer |
| `compiler/compilationCache.ml` | `src/compiler/CompilationCache.hx` | Server cache |
| `compiler/pipeThings.ml` | `src/compiler/PipeThings.hx` | Client/server transport (host streams, see header) |
| `compiler/tasks.ml` | `src/compiler/Tasks.hx` | Server maintenance tasks |
| `compiler/server/server.ml` | `src/compiler/server/Server.hx` | Server loop, `--connect`, `--server-connect` |
| `compiler/server/serverCache.ml` | `src/compiler/server/ServerCache.hx` | Module cache, `hxb_reader_api_server` |
| `compiler/server/serverCompilationContext.ml` | `src/compiler/server/ServerCompilationContext.hx` | Server context |
| `compiler/server/serverConfig.ml` | `src/compiler/server/ServerConfig.hx` | Server configuration |
| `compiler/server/serverMessage.ml` | `src/compiler/server/ServerMessage.hx` | Verbose server messages |
| `context/commonCache.ml` | `src/context/CommonCache.hx` | Cache contexts and signatures |
| `compiler/displayOutput.ml` | `src/compiler/DisplayOutput.hx` | Display services |
| `compiler/displayProcessing.ml` | `src/compiler/DisplayProcessing.hx` | Display services |
| `compiler/displayProcessingGlobals.ml` | `src/compiler/DisplayProcessingGlobals.hx` | Display services |
| `context/display/diagnostics.ml` | `src/context/display/Diagnostics.hx` | Display services |
| `context/display/diagnosticsPrinter.ml` | `src/context/display/DiagnosticsPrinter.hx` | Display services |
| `context/display/display.ml` | `src/context/display/Display.hx` | Display services |
| `context/display/displayEmitter.ml` | `src/context/display/DisplayEmitter.hx` | Display services |
| `context/display/displayException.ml` | `src/context/display/DisplayException.hx` | Display services |
| `context/display/displayFields.ml` | `src/context/display/DisplayFields.hx` | Display services |
| `context/display/displayJson.ml` | `src/context/display/DisplayJson.hx` | Display services; `server/*` cache methods need the server milestone, `server/module` HXB input |
| `context/display/displayMemory.ml` | `src/context/display/DisplayMemory.hx` | Display services; memory sizes need `Memory.memSize` (no OCaml Obj reflection) |
| `context/display/displayPath.ml` | `src/context/display/DisplayPath.hx` | Display services |
| `context/display/displayTexpr.ml` | `src/context/display/DisplayTexpr.hx` | Display services |
| `context/display/displayToplevel.ml` | `src/context/display/DisplayToplevel.hx` | Display services |
| `context/display/documentSymbols.ml` | `src/context/display/DocumentSymbols.hx` | Display services |
| `context/display/exprPreprocessing.ml` | `src/context/display/ExprPreprocessing.hx` | Display services |
| `context/display/findReferences.ml` | `src/context/display/FindReferences.hx` | Display services |
| `context/display/statistics.ml` | `src/context/display/Statistics.hx` | Display services |
| `context/display/syntaxExplorer.ml` | `src/context/display/SyntaxExplorer.hx` | Display services |
| `context/memory.ml` | `src/context/Memory.hx` | Request types; object sizes are unavailable on the host runtimes |
| `core/display/completionItem.ml` | `src/core/display/CompletionItem.hx` | Display services |
| `core/json/genjson.ml` | `src/core/json/Genjson.hx` | Display serialization |
| `core/json/jsonRpc.ml` | `src/core/json/JsonRpc.hx` | JSON-RPC protocol |
| `core/json/jsonrpc_handler.ml` | `src/core/json/JsonrpcHandler.hx` | JSON-RPC handler |
| `typing/typerDisplay.ml` | `src/typing/TyperDisplay.hx` | Display services |

## Deferred or scope-review areas

These entries are recorded so absence is not mistaken for a completed translation.
A scope-review entry is not a blanket exclusion of shared batch-compiler helpers.

| Upstream under `haxe/src/` | Reason |
| --- | --- |
| `codegen/genxml.ml` | Standalone XML output deferred; RTTI serializer is in scope and compiled |
| `codegen/jClass.ml` | Other target/library support |
| `codegen/javaModern.ml` | Other target/library support |
| `codegen/swfLoader.ml` | Other target/library support |
| `context/nativeLibraryHandler.ml` | SWF/JVM library handlers (`SwfLoader`, `JavaModern`); the HXB branch is translated |
| `context/sourcemaps.ml` | Ordinary output-target source maps |
| `core/json/jsonRpcSocket.ml` | Display/server JSON-RPC transport |
| `filters/ES6Ctors.ml` | Other target/library support |
| `generators/cpp/cppAst.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/cppAstTools.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/cppContext.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/cppError.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/cppMarshalling.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/cppRetyper.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/cppSourceWriter.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/cppStrings.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/cppTypeUtils.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/filters/cppFilterAutoCast.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/filters/cppFilterValueType.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/gen/cppCppia.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/gen/cppGen.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/gen/cppGenClassHeader.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/gen/cppGenClassImplementation.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/gen/cppGenEnum.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/gen/cppGenInterfaceHeader.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/gen/cppGenInterfaceImplementation.ml` | Ordinary output-target generator/runtime |
| `generators/cpp/gen/cppReferences.ml` | Ordinary output-target generator/runtime |
| `generators/flashProps.ml` | Ordinary output-target generator/runtime |
| `generators/gctx.ml` | Ordinary output-target generator/runtime |
| `generators/gencpp.ml` | Ordinary output-target generator/runtime |
| `generators/genhl.ml` | Ordinary output-target generator/runtime |
| `generators/genhxold.ml` | Ordinary output-target generator/runtime |
| `generators/genjs.ml` | Ordinary output-target generator/runtime |
| `generators/genjvm.ml` | Ordinary output-target generator/runtime |
| `generators/genlua.ml` | Ordinary output-target generator/runtime |
| `generators/genneko.ml` | Ordinary output-target generator/runtime |
| `generators/genphp7.ml` | Ordinary output-target generator/runtime |
| `generators/genpy.ml` | Ordinary output-target generator/runtime |
| `generators/genshared.ml` | Ordinary generator preprocessing (JVM metadata and interface generation) |
| `generators/genswf.ml` | Ordinary output-target generator/runtime |
| `generators/genswf9.ml` | Ordinary output-target generator/runtime |
| `generators/hl2c.ml` | Ordinary output-target generator/runtime |
| `generators/hlcode.ml` | Ordinary output-target generator/runtime |
| `generators/hlinterp.ml` | Ordinary output-target generator/runtime |
| `generators/hlopt.ml` | Ordinary output-target generator/runtime |
| `generators/jsSourcemap.ml` | Ordinary output-target generator/runtime |
| `generators/jvm/jvmAttribute.ml` | Ordinary output-target generator/runtime |
| `generators/jvm/jvmBuilder.ml` | Ordinary output-target generator/runtime |
| `generators/jvm/jvmClass.ml` | Ordinary output-target generator/runtime |
| `generators/jvm/jvmCode.ml` | Ordinary output-target generator/runtime |
| `generators/jvm/jvmConstantPool.ml` | Ordinary output-target generator/runtime |
| `generators/jvm/jvmData.ml` | Ordinary output-target generator/runtime |
| `generators/jvm/jvmFunctions.ml` | Ordinary output-target generator/runtime |
| `generators/jvm/jvmGlobals.ml` | Ordinary output-target generator/runtime |
| `generators/jvm/jvmMethod.ml` | Ordinary output-target generator/runtime |
| `generators/jvm/jvmSignature.ml` | Ordinary output-target generator/runtime |
| `generators/jvm/jvmVerificationTypeInfo.ml` | Ordinary output-target generator/runtime |
| `generators/jvm/jvmWriter.ml` | Ordinary output-target generator/runtime |
| `lazy.ml` | OCaml build/runtime adapter; no mechanical compiler-module port |
| `macro/eval/bytes/evalBytesLower.ml` | Macro runtime/API milestone |
| `macro/eval/bytes/evalBytesUpper.ml` | Macro runtime/API milestone |
| `macro/eval/bytes/evalBytes_E_L79.ml` | Macro runtime/API milestone |
| `macro/eval/bytes/evalBytes_L1020.ml` | Macro runtime/API milestone |
| `macro/eval/bytes/evalBytes_U1021.ml` | Macro runtime/API milestone |
| `macro/eval/bytes/evalBytes_U79.ml` | Macro runtime/API milestone |
| `macro/eval/eval.ml` | Macro runtime/API milestone |
| `macro/eval/evalArray.ml` | Macro runtime/API milestone |
| `macro/eval/evalAtomic.ml` | Macro runtime/API milestone |
| `macro/eval/evalBytes.ml` | Macro runtime/API milestone |
| `macro/eval/evalContext.ml` | Macro runtime/API milestone |
| `macro/eval/evalDataApi.ml` | Macro runtime/API milestone |
| `macro/eval/evalDebug.ml` | Macro runtime/API milestone |
| `macro/eval/evalDebugMisc.ml` | Macro runtime/API milestone |
| `macro/eval/evalDebugSocket.ml` | Macro runtime/API milestone |
| `macro/eval/evalDecode.ml` | Macro runtime/API milestone |
| `macro/eval/evalEmitter.ml` | Macro runtime/API milestone |
| `macro/eval/evalEncode.ml` | Macro runtime/API milestone |
| `macro/eval/evalExceptions.ml` | Macro runtime/API milestone |
| `macro/eval/evalField.ml` | Macro runtime/API milestone |
| `macro/eval/evalHash.ml` | Macro runtime/API milestone |
| `macro/eval/evalIntegers.ml` | Macro runtime/API milestone |
| `macro/eval/evalJit.ml` | Macro runtime/API milestone |
| `macro/eval/evalJitContext.ml` | Macro runtime/API milestone |
| `macro/eval/evalLuv.ml` | Macro runtime/API milestone |
| `macro/eval/evalMain.ml` | Macro runtime/API milestone |
| `macro/eval/evalMisc.ml` | Macro runtime/API milestone |
| `macro/eval/evalPrinting.ml` | Macro runtime/API milestone |
| `macro/eval/evalPrototype.ml` | Macro runtime/API milestone |
| `macro/eval/evalSsl.ml` | Macro runtime/API milestone |
| `macro/eval/evalStackTrace.ml` | Macro runtime/API milestone |
| `macro/eval/evalStdLib.ml` | Macro runtime/API milestone |
| `macro/eval/evalString.ml` | Macro runtime/API milestone |
| `macro/eval/evalThread.ml` | Macro runtime/API milestone |
| `macro/eval/evalTypes.ml` | Macro runtime/API milestone |
| `macro/eval/evalValue.ml` | Macro runtime/API milestone |
| `macro/macroApi.ml` | Macro runtime/API milestone |
| `prebuild.ml` | OCaml build/runtime adapter; no mechanical compiler-module port |
| `typing/macroContext.ml` | Macro context milestone |

## Additional draft support files

- `src/core/MetaList.hx`
- `src/core/WarningList.hx`
- `src/macros/eval/EvalLock.hx`: OCaml's runtime lock for Eval threads on host
  threads (no upstream module; see its comment)

## Next work

The previously pending in-scope module counterparts are now written. The ten
candidates moved to the deferred table were reviewed against the source-only HXB
milestone: they implement server transport/diagnostics, native-library input,
JSON services, source maps, or ordinary generator support.

File presence does not prove complete one-to-one coverage of the 33 pre-existing
counterparts. Their earlier subset implementations and shared hooks in deferred
areas remain an explicit source-coverage limitation. Keep that distinction visible
when reconciling APIs and bringing the compiler together. No compilation or tests
were performed during these translation batches.
