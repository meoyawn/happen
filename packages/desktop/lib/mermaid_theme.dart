// Color role mapping adapted from mermaid_flutter's MaterialMermaidTheme.
// Copyright (c) 2026 Dominik Roszkowski
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import 'package:material_ui/material_ui.dart';
import 'package:mermaid_core/mermaid_core.dart' as mermaid;

mermaid.MermaidTheme mermaidTheme(ThemeData theme) {
  final scheme = theme.colorScheme;
  final body = theme.textTheme.bodyMedium;
  final defaults = scheme.brightness == Brightness.dark
    ? mermaid.MermaidTheme.darkTheme : mermaid.MermaidTheme.defaultTheme;
  mermaid.Color color(Color value) => mermaid.Color(value.toARGB32());

  // Keep each fill paired with its contrasting label color and a distinct
  // border. Mermaid uses separate named fields for the same categorical palette.
  final palette = [
    (scheme.primaryContainer, scheme.onPrimaryContainer, scheme.primary),
    (scheme.secondaryContainer, scheme.onSecondaryContainer, scheme.secondary),
    (scheme.tertiaryContainer, scheme.onTertiaryContainer, scheme.tertiary),
    (scheme.errorContainer, scheme.onErrorContainer, scheme.error),
    (scheme.primary, scheme.onPrimary, scheme.primaryContainer),
    (scheme.secondary, scheme.onSecondary, scheme.secondaryContainer),
    (scheme.tertiary, scheme.onTertiary, scheme.tertiaryContainer),
    (scheme.error, scheme.onError, scheme.errorContainer),
    (scheme.surfaceContainerHighest, scheme.onSurface, scheme.outline),
    (scheme.surfaceContainerHigh, scheme.onSurface, scheme.outlineVariant),
    (scheme.surfaceContainer, scheme.onSurface, scheme.onSurfaceVariant),
    (scheme.surfaceContainerLow, scheme.onSurface, scheme.onSurface),
  ].map((role) => (fill: color(role.$1), label: color(role.$2), border: color(role.$3))).toList();
  final fills = [for (final role in palette) role.fill];
  final labels = [for (final role in palette) role.label];
  final borders = [for (final role in palette) role.border];
  final surface = color(scheme.surface);
  final ink = color(scheme.onSurface);
  final outline = color(scheme.outline);
  final edge = color(scheme.onSurfaceVariant);
  final edgeBackground = color(scheme.surfaceContainerHigh);
  const flowEdge = mermaid.Color(0xff405163);

  return mermaid.MermaidTheme(
    background: surface,
    primaryColor: fills[0],
    primaryTextColor: labels[0],
    primaryBorderColor: borders[0],
    secondaryColor: fills[1],
    lineColor: flowEdge,
    arrowheadColor: flowEdge,
    textColor: ink,
    nodeBorder: const mermaid.Color(0xff607a92),
    mainBkg: fills[0],
    // Translucent subgraph fills preserve the depth of nested clusters.
    clusterBkg: const mermaid.Color(0x28687991),
    clusterBorder: const mermaid.Color(0xff697b8c),
    titleColor: ink,
    edgeLabelBackground: edgeBackground,
    fontFamily: body?.fontFamily ?? defaults.fontFamily,
    fontSize: body?.fontSize ?? defaults.fontSize,
    cScale0: fills[0],
    cScale1: fills[1],
    cScale2: fills[2],
    cScale3: fills[3],
    cScale4: fills[4],
    cScale5: fills[5],
    cScale6: fills[6],
    cScale7: fills[7],
    cScale8: fills[8],
    cScale9: fills[9],
    cScale10: fills[10],
    cScale11: fills[11],
    cScaleInv0: labels[0],
    cScaleInv1: labels[1],
    cScaleInv2: labels[2],
    cScaleInv3: labels[3],
    cScaleInv4: labels[4],
    cScaleInv5: labels[5],
    cScaleInv6: labels[6],
    cScaleInv7: labels[7],
    cScaleInv8: labels[8],
    cScaleInv9: labels[9],
    cScaleInv10: labels[10],
    cScaleInv11: labels[11],
    cScaleLabel0: labels[0],
    cScaleLabel1: labels[1],
    cScaleLabel2: labels[2],
    cScaleLabel3: labels[3],
    cScaleLabel4: labels[4],
    cScaleLabel5: labels[5],
    cScaleLabel6: labels[6],
    cScaleLabel7: labels[7],
    cScaleLabel8: labels[8],
    cScaleLabel9: labels[9],
    cScaleLabel10: labels[10],
    cScaleLabel11: labels[11],
    cScalePeer0: borders[0],
    cScalePeer1: borders[1],
    cScalePeer2: borders[2],
    cScalePeer3: borders[3],
    cScalePeer4: borders[4],
    cScalePeer5: borders[5],
    cScalePeer6: borders[6],
    cScalePeer7: borders[7],
    cScalePeer8: borders[8],
    cScalePeer9: borders[9],
    cScalePeer10: borders[10],
    cScalePeer11: borders[11],
    // Pie slices share a label color and use only container and surface fills.
    pie1: fills[0],
    pie2: fills[1],
    pie3: fills[2],
    pie4: fills[3],
    pie5: fills[8],
    pie6: fills[9],
    pie7: fills[10],
    pie8: fills[11],
    pie9: fills[0],
    pie10: fills[1],
    pie11: fills[2],
    pie12: fills[3],
    pieStrokeColor: outline,
    pieOuterStrokeColor: outline,
    pieSectionTextColor: ink,
    pieLegendTextColor: ink,
    pieTitleTextColor: ink,
    git0: borders[0],
    git1: borders[1],
    git2: borders[2],
    git3: borders[3],
    git4: borders[4],
    git5: borders[5],
    git6: borders[6],
    git7: borders[7],
    gitInv0: labels[4],
    gitInv1: labels[5],
    gitInv2: labels[6],
    gitInv3: labels[7],
    gitInv4: labels[0],
    gitInv5: labels[1],
    gitInv6: labels[2],
    gitInv7: labels[3],
    gitBranchLabel0: labels[4],
    gitBranchLabel1: labels[5],
    gitBranchLabel2: labels[6],
    gitBranchLabel3: labels[7],
    gitBranchLabel4: labels[0],
    gitBranchLabel5: labels[1],
    gitBranchLabel6: labels[2],
    gitBranchLabel7: labels[3],
    commitLabelColor: labels[1],
    commitLabelBackground: fills[1],
    tagLabelColor: labels[2],
    tagLabelBackground: fills[2],
    tagLabelBorder: borders[2],
    actorBkg: fills[0],
    actorBorder: borders[0],
    actorTextColor: labels[0],
    actorLineColor: edge,
    signalColor: edge,
    signalTextColor: ink,
    labelBoxBkgColor: fills[1],
    labelBoxBorderColor: borders[1],
    labelTextColor: labels[1],
    loopTextColor: ink,
    noteBkgColor: fills[2],
    noteBorderColor: borders[2],
    noteTextColor: labels[2],
    activationBkgColor: fills[8],
    activationBorderColor: outline,
    fillType0: fills[0],
    fillType1: fills[1],
    fillType2: fills[2],
    fillType3: fills[3],
    fillType4: fills[8],
    fillType5: fills[9],
    fillType6: fills[10],
    fillType7: fills[11],
    quadrant1Fill: fills[0],
    quadrant2Fill: fills[1],
    quadrant3Fill: fills[2],
    quadrant4Fill: fills[8],
    quadrant1TextFill: labels[0],
    quadrant2TextFill: labels[1],
    quadrant3TextFill: labels[2],
    quadrant4TextFill: labels[8],
    quadrantPointFill: borders[0],
    quadrantPointTextFill: ink,
    quadrantXAxisTextFill: ink,
    quadrantYAxisTextFill: ink,
    quadrantInternalBorderStrokeFill: color(scheme.outlineVariant),
    quadrantExternalBorderStrokeFill: outline,
    quadrantTitleFill: ink,
    attributeBackgroundColorOdd: color(scheme.surfaceContainerLowest),
    attributeBackgroundColorEven: fills[11],
    rowOdd: color(scheme.surfaceContainerLowest),
    rowEven: fills[11],
    venn1: fills[0],
    venn2: fills[1],
    venn3: fills[2],
    venn4: fills[3],
    venn5: fills[4],
    venn6: fills[5],
    venn7: fills[6],
    venn8: fills[7],
    vennTitleTextColor: ink,
    vennSetTextColor: ink,
    requirementBackground: fills[0],
    requirementBorderColor: borders[0],
    requirementTextColor: labels[0],
    relationColor: edge,
    relationLabelBackground: edgeBackground,
    relationLabelColor: ink,
    xyChartPlotColorPalette: fills,
  );
}
