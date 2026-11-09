//
//  PanelView.swift
//  PrimoKKMK1Bridge
//
//  Created by George Senger on 11/8/2026.
//  Copyright © 2026 Primo Studios. All rights reserved.
//
//  Licensed under the MIT License. See LICENSE in the project root or
//  https://github.com/gsenger3/PrimoKKMK1Bridge/blob/main/LICENSE
//
//  The drawn S-series MK1 panel: every button, knob, display and strip, labelled with what it does on the
//  current page. Click a control to select it for the inspector.

import SwiftUI

private let panelColor = Color(red: 0.16, green: 0.17, blue: 0.19)
private let capColor = Color(white: 0.20)
private let litCapColor = Color(white: 0.31)
private let edgeColor = Color(white: 0.40)
private let valueColor = Color(red: 0.55, green: 0.84, blue: 1.0)
private let noteColor = Color(white: 0.62)
private let outlineColor = Color(red: 0.72, green: 0.70, blue: 1.0)  // the Navigate arrows' lit edge
private let lcdColor = Color(red: 0.55, green: 0.82, blue: 1.0)       // the displays' blue backlit text
private let lcdBackground = Color(red: 0.03, green: 0.07, blue: 0.16)

struct PanelView: View {
    @EnvironmentObject var model: EditorModel

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / panelSize.width, geo.size.height / panelSize.height)
            canvas
                .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: panelSize.width * scale, height: panelSize.height * scale, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(panelSize.width / panelSize.height, contentMode: .fit)
    }

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [Color(white: 0.21), panelColor], startPoint: .top, endPoint: .bottom))
                .frame(width: panelSize.width, height: panelSize.height)
                .onTapGesture { model.selection = nil }

            Text("Primo KK MK1 Control Editor  ·  S-series MK1")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(white: 0.45))
                .position(x: displayCenter(4).x + 30, y: 205)

            ForEach(0..<9, id: \.self) { i in displayCell(i) }
            ForEach(0..<8, id: \.self) { k in knob(k) }
            navigateKnob
            ForEach(panelButtons, id: \.name) { spec in button(spec) }

            strip(.pitchStrip, title: "PITCH", x: 45)
            strip(.modStrip, title: "MOD", x: 85)
            keys
        }
    }

    // MARK: pieces

    private func isSelected(_ id: ControlID) -> Bool { model.selection == id }

    private func labels(_ lines: [String], width: CGFloat) -> some View {
        VStack(spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(.system(size: 8.5, weight: i == 0 ? .semibold : .regular))
                    .foregroundStyle(i == 0 ? valueColor : noteColor)
                    .lineLimit(1)
                    .frame(width: width)
            }
        }
    }

    private func button(_ spec: PanelButtonSpec) -> some View {
        let id = ControlID.button(spec.name)
        let lit = model.isAssigned(id)
        let selected = isSelected(id)
        // Outlined (the Navigate arrows): a dark cap whose edge lights up; otherwise the whole cap lights up.
        let fill = spec.outlined ? Color(white: 0.08) : (lit ? litCapColor : capColor)
        let edge = selected ? Color.accentColor : (spec.outlined && lit ? outlineColor : edgeColor)
        let edgeWidth: CGFloat = selected ? 2.5 : (spec.outlined && lit ? 1.6 : 0.8)
        return VStack(spacing: 3) {
            Text(spec.cap)
                .font(.system(size: spec.cap.count <= 2 ? 11 : 8.5, weight: .bold))
                .foregroundStyle(spec.outlined && lit ? outlineColor : .white.opacity(lit ? 0.95 : 0.55))
                .frame(width: spec.width, height: 22)
                .background(RoundedRectangle(cornerRadius: 4).fill(fill))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(edge, lineWidth: edgeWidth))
                .shadow(color: lit ? (spec.outlined ? outlineColor.opacity(0.5) : .white.opacity(0.18)) : .clear, radius: 3)
            labels(model.panelLines(id), width: spec.width + 18)
        }
        .frame(width: spec.width + 18, height: 50, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = id }
        .help(buttonTitle(spec.name))
        .position(x: spec.x, y: spec.y + 14)
    }

    private func knobFace(diameter: CGFloat, selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.36), Color(white: 0.13)], center: .topLeading,
                                     startRadius: 2, endRadius: diameter))
            Circle().stroke(selected ? Color.accentColor : edgeColor, lineWidth: selected ? 2.5 : 0.8)
            Capsule().fill(.white.opacity(0.85)).frame(width: 2, height: diameter * 0.28).offset(y: -diameter * 0.28)
        }
        .frame(width: diameter, height: diameter)
    }

    private func knob(_ k: Int) -> some View {
        let id = ControlID.knob(k)
        let c = knobCenter(k)
        // No label under the knob: as on the keyboard, the display below it says what it does.
        return knobFace(diameter: knobDiameter, selected: isSelected(id))
            .background(Circle().stroke(outlineColor.opacity(0.35), lineWidth: 1.5)
                .frame(width: knobDiameter + 6, height: knobDiameter + 6))
            .contentShape(Circle())
            .onTapGesture { model.selection = id }
            .help("Knob \(k + 1)")
            .position(c)
    }

    private var navigateKnob: some View {
        let id = ControlID.navigateKnob
        let c = navigateKnobCenter
        let d = navigateKnobDiameter
        return VStack(spacing: 3) {
            knobFace(diameter: d, selected: isSelected(id))
                .background(Circle().stroke(outlineColor.opacity(0.45), lineWidth: 2).frame(width: d + 8, height: d + 8))
            labels(model.panelLines(id), width: 84)
        }
        .frame(width: 84, height: d + 32, alignment: .top)
        .contentShape(Rectangle())
        .onTapGesture { model.selection = id }
        .help("Navigate knob: turn, touch and press")
        .position(x: c.x, y: c.y - d / 2 + (d + 32) / 2)
    }

    /// A display as on the keyboard: a value bar on top, then two lines of 8 characters. Displays 1-8 belong to
    /// the knob above them (clicking one selects that knob); display 0 is the page's overview.
    private func displayCell(_ i: Int) -> some View {
        let (top, bottom) = model.displayText(i)
        let c = displayCenter(i)
        let selected = i > 0 && isSelected(.knob(i - 1))
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                let lit = model.displayBar(i).map { Int(($0 * 9).rounded()) } ?? 0
                ForEach(0..<9, id: \.self) { s in
                    Capsule()
                        .fill(s < lit ? lcdColor : lcdColor.opacity(0.10))
                        .frame(width: 4, height: 2.5)
                }
            }
            .opacity(i == 0 ? 0 : 1)
            Text(String(top.prefix(8)))
            Text(String(bottom.prefix(8)))
        }
        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
        .foregroundStyle(lcdColor)
        .padding(.horizontal, 5)
        .frame(width: 58, height: 52, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3).fill(lcdBackground))
        .overlay(RoundedRectangle(cornerRadius: 3)
            .stroke(selected ? Color.accentColor : Color(white: 0.30), lineWidth: selected ? 2.5 : 0.8))
        .contentShape(Rectangle())
        .onTapGesture { if i > 0 { model.selection = .knob(i - 1) } }
        .position(c)
    }

    private func strip(_ id: ControlID, title: String, x: CGFloat) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(white: 0.10))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected(id) ? Color.accentColor : edgeColor, lineWidth: isSelected(id) ? 2.5 : 0.8))
                .frame(width: 20, height: 112)
            Text(title).font(.system(size: 7.5, weight: .bold)).foregroundStyle(noteColor)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selection = id }
        .position(x: x, y: 330)
    }

    /// 61 keys: 36 white keys from C to C, with the black keys of five octaves.
    private var keys: some View {
        let left: CGFloat = 115, right: CGFloat = 1045, top: CGFloat = 262, bottom: CGFloat = 398
        let whiteWidth = (right - left) / 36
        let blackOffsets = [0, 1, 3, 4, 5]  // a black key after C, D, F, G, A
        return ZStack(alignment: .topLeading) {
            ForEach(0..<36, id: \.self) { w in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(white: 0.94))
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color(white: 0.55), lineWidth: 0.6))
                    .frame(width: whiteWidth - 1, height: bottom - top)
                    .offset(x: left + CGFloat(w) * whiteWidth, y: top)
            }
            ForEach(0..<5, id: \.self) { octave in
                ForEach(blackOffsets, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(white: 0.08))
                        .frame(width: whiteWidth * 0.6, height: (bottom - top) * 0.6)
                        .offset(x: left + CGFloat(octave * 7 + i + 1) * whiteWidth - whiteWidth * 0.3, y: top)
                }
            }
            if isSelected(.keys) {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.accentColor, lineWidth: 2.5)
                    .frame(width: right - left, height: bottom - top)
                    .offset(x: left, y: top)
            }
        }
        .frame(width: panelSize.width, height: panelSize.height, alignment: .topLeading)
        .contentShape(Rectangle().size(width: right - left, height: bottom - top).offset(x: left, y: top))
        .onTapGesture { model.selection = .keys }
    }
}
