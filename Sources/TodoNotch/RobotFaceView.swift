import SwiftUI
import TodoNotchCore

enum RobotExpression: CaseIterable, Equatable {
    case crying        // 1. 大哭流泪（超期/漏跑）
    case sobbing       // 2. 爆哭抽泣
    case angryError    // 3. 怒眉报错
    case dizzy         // 4. 晕眩 X X
    case happySmile    // 5. 开心弯眼笑
    case starry        // 6. 星星眼
    case love          // 7. 爱心眼
    case wink          // 8. 俏皮眨单眼
    case blinking      // 9. 自然眨眼
    case curious       // 10. 好奇张望
    case thinking      // 11. 挑眉思考
    case surprised     // 12. 惊讶 O O
    case coolShades    // 13. 墨镜酷哥
    case sleepy        // 14. 犯困打盹
    case shyBlush      // 15. 害羞脸红
    case catFace       // 16. 卖萌猫脸 :3
    case focusScan     // 17. 专注扫描
    case sweatDrop     // 18. 擦汗催促
}

struct RobotFaceView: View {
    let presentation: RobotPresentation
    var size: CGFloat = 20

    @State private var tick: Int = 0
    @State private var expression: RobotExpression = .curious
    @State private var glanceX: CGFloat = 0
    @State private var bounceY: CGFloat = 0
    @State private var tearOffset: CGFloat = 0
    @State private var animTimer: Timer?

    private var accentColor: Color {
        switch presentation.mood {
        case .idle: return Color(red: 0.78, green: 0.90, blue: 0.98)
        case .running: return Color(red: 0.22, green: 0.74, blue: 0.97)
        case .success: return Color(red: 0.13, green: 0.77, blue: 0.37)
        case .attention: return Color(red: 0.98, green: 0.66, blue: 0.12)
        case .error: return Color(red: 1.0, green: 0.30, blue: 0.31)
        case .overdue: return Color(red: 1.0, green: 0.36, blue: 0.48)
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                // Robot visor head
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .fill(accentColor.opacity(0.20))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                            .stroke(accentColor.opacity(0.92), lineWidth: max(1.1, size * 0.06))
                    )

                faceContent
                    .offset(
                        x: presentation.animateIdle ? glanceX : 0,
                        y: presentation.animateIdle ? bounceY : 0
                    )
            }
            .frame(width: size, height: size * 0.86)
            .clipped()

            if presentation.showMutedBadge {
                Image(systemName: "moon.fill")
                    .font(.system(size: max(6.5, size * 0.34), weight: .bold))
                    .foregroundColor(Color(white: 0.92))
                    .padding(1.2)
                    .background(Color.black.opacity(0.9))
                    .clipShape(Circle())
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: size + 2, height: size)
        .onAppear {
            pickExpressionForMood(initial: true)
            animTimer?.invalidate()
            animTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                Task { @MainActor in tick &+= 1 }
            }
        }
        .onDisappear {
            animTimer?.invalidate()
            animTimer = nil
        }
        .onChange(of: tick) { _, _ in
            stepAnimation()
        }
        .onChange(of: presentation.mood) { _, _ in
            pickExpressionForMood(initial: true)
        }
    }

    // MARK: - 18 Rich Vector Expressions

    @ViewBuilder
    private var faceContent: some View {
        let s = size
        let tearBlue = Color(red: 0.38, green: 0.78, blue: 1.0)
        let blushPink = Color(red: 1.0, green: 0.48, blue: 0.62)

        switch expression {
        case .crying:
            ZStack {
                // Streaming tear columns
                HStack(spacing: s * 0.28) {
                    Capsule().fill(tearBlue.opacity(0.88)).frame(width: s * 0.12, height: s * 0.38)
                        .offset(y: s * 0.16 + tearOffset)
                    Capsule().fill(tearBlue.opacity(0.88)).frame(width: s * 0.12, height: s * 0.38)
                        .offset(y: s * 0.16 + tearOffset)
                }
                VStack(spacing: s * 0.08) {
                    // T_T crying eyes
                    HStack(spacing: s * 0.16) {
                        Capsule().fill(accentColor).frame(width: s * 0.24, height: max(1.4, s * 0.08))
                        Capsule().fill(accentColor).frame(width: s * 0.24, height: max(1.4, s * 0.08))
                    }
                    // Sad open mouth
                    SadArc().stroke(accentColor, style: StrokeStyle(lineWidth: max(1.2, s * 0.07), lineCap: .round))
                        .frame(width: s * 0.24, height: s * 0.12)
                }
            }

        case .sobbing:
            ZStack {
                // Flying tear drops
                HStack(spacing: s * 0.52) {
                    Circle().fill(tearBlue).frame(width: s * 0.13, height: s * 0.13).offset(y: tearOffset)
                    Circle().fill(tearBlue).frame(width: s * 0.13, height: s * 0.13).offset(y: tearOffset)
                }
                VStack(spacing: s * 0.06) {
                    HStack(spacing: s * 0.10) {
                        Text(">").font(.system(size: s * 0.30, weight: .heavy, design: .rounded)).foregroundColor(accentColor)
                        Text("<").font(.system(size: s * 0.30, weight: .heavy, design: .rounded)).foregroundColor(accentColor)
                    }
                    Circle().fill(accentColor.opacity(0.85)).frame(width: s * 0.16, height: s * 0.12)
                }
            }

        case .angryError:
            VStack(spacing: s * 0.06) {
                HStack(spacing: s * 0.14) {
                    Capsule().fill(accentColor).frame(width: s * 0.22, height: s * 0.11).rotationEffect(.degrees(22))
                    Capsule().fill(accentColor).frame(width: s * 0.22, height: s * 0.11).rotationEffect(.degrees(-22))
                }
                SadArc().stroke(accentColor, style: StrokeStyle(lineWidth: max(1.2, s * 0.07), lineCap: .round))
                    .frame(width: s * 0.24, height: s * 0.10)
            }

        case .dizzy:
            VStack(spacing: s * 0.05) {
                HStack(spacing: s * 0.14) {
                    Text("×").font(.system(size: s * 0.34, weight: .black, design: .rounded)).foregroundColor(accentColor)
                    Text("×").font(.system(size: s * 0.34, weight: .black, design: .rounded)).foregroundColor(accentColor)
                }
                Capsule().fill(accentColor.opacity(0.8)).frame(width: s * 0.22, height: max(1.1, s * 0.06)).rotationEffect(.degrees(-10))
            }

        case .happySmile:
            VStack(spacing: s * 0.07) {
                HStack(spacing: s * 0.16) {
                    ArcSmile().stroke(accentColor, style: StrokeStyle(lineWidth: max(1.3, s * 0.08), lineCap: .round))
                        .frame(width: s * 0.22, height: s * 0.13)
                    ArcSmile().stroke(accentColor, style: StrokeStyle(lineWidth: max(1.3, s * 0.08), lineCap: .round))
                        .frame(width: s * 0.22, height: s * 0.13)
                }
                HStack(spacing: s * 0.08) {
                    Circle().fill(blushPink.opacity(0.75)).frame(width: s * 0.11, height: s * 0.08)
                    MouthSmile().stroke(accentColor, style: StrokeStyle(lineWidth: max(1.1, s * 0.065), lineCap: .round))
                        .frame(width: s * 0.22, height: s * 0.10)
                    Circle().fill(blushPink.opacity(0.75)).frame(width: s * 0.11, height: s * 0.08)
                }
            }

        case .starry:
            VStack(spacing: s * 0.05) {
                HStack(spacing: s * 0.14) {
                    Image(systemName: "sparkle").font(.system(size: s * 0.26, weight: .bold)).foregroundColor(.yellow)
                    Image(systemName: "sparkle").font(.system(size: s * 0.26, weight: .bold)).foregroundColor(.yellow)
                }
                MouthSmile().stroke(accentColor, style: StrokeStyle(lineWidth: max(1.1, s * 0.065), lineCap: .round))
                    .frame(width: s * 0.22, height: s * 0.10)
            }

        case .love:
            VStack(spacing: s * 0.05) {
                HStack(spacing: s * 0.14) {
                    Image(systemName: "heart.fill").font(.system(size: s * 0.23)).foregroundColor(blushPink)
                    Image(systemName: "heart.fill").font(.system(size: s * 0.23)).foregroundColor(blushPink)
                }
                MouthSmile().stroke(accentColor, style: StrokeStyle(lineWidth: max(1.1, s * 0.065), lineCap: .round))
                    .frame(width: s * 0.20, height: s * 0.09)
            }

        case .wink:
            VStack(spacing: s * 0.07) {
                HStack(spacing: s * 0.18) {
                    Circle().fill(accentColor).frame(width: s * 0.20, height: s * 0.20)
                    ArcSmile().stroke(accentColor, style: StrokeStyle(lineWidth: max(1.3, s * 0.08), lineCap: .round))
                        .frame(width: s * 0.22, height: s * 0.12)
                }
                MouthSmile().stroke(accentColor, style: StrokeStyle(lineWidth: max(1.1, s * 0.065), lineCap: .round))
                    .frame(width: s * 0.20, height: s * 0.09)
            }

        case .blinking:
            VStack(spacing: s * 0.09) {
                HStack(spacing: s * 0.18) {
                    Capsule().fill(accentColor).frame(width: s * 0.20, height: max(1.2, s * 0.06))
                    Capsule().fill(accentColor).frame(width: s * 0.20, height: max(1.2, s * 0.06))
                }
                Capsule().fill(accentColor.opacity(0.65)).frame(width: s * 0.16, height: max(1.0, s * 0.05))
            }

        case .curious:
            VStack(spacing: s * 0.07) {
                HStack(spacing: s * 0.16) {
                    Circle().fill(accentColor).frame(width: s * 0.22, height: s * 0.22)
                    Circle().fill(accentColor).frame(width: s * 0.15, height: s * 0.15)
                }
                Circle().stroke(accentColor, lineWidth: max(1.0, s * 0.06)).frame(width: s * 0.11, height: s * 0.11)
            }

        case .thinking:
            VStack(spacing: s * 0.06) {
                HStack(spacing: s * 0.16) {
                    Capsule().fill(accentColor).frame(width: s * 0.19, height: s * 0.16)
                    Capsule().fill(accentColor).frame(width: s * 0.19, height: s * 0.11).offset(y: -s * 0.04)
                }
                Capsule().fill(accentColor.opacity(0.85)).frame(width: s * 0.18, height: max(1.1, s * 0.06)).offset(x: s * 0.05)
            }

        case .surprised:
            VStack(spacing: s * 0.06) {
                HStack(spacing: s * 0.16) {
                    Circle().stroke(accentColor, lineWidth: max(1.3, s * 0.075)).frame(width: s * 0.21, height: s * 0.21)
                    Circle().stroke(accentColor, lineWidth: max(1.3, s * 0.075)).frame(width: s * 0.21, height: s * 0.21)
                }
                Circle().fill(accentColor).frame(width: s * 0.12, height: s * 0.14)
            }

        case .coolShades:
            VStack(spacing: s * 0.07) {
                HStack(spacing: s * 0.06) {
                    RoundedRectangle(cornerRadius: s * 0.06).fill(Color.black)
                        .overlay(RoundedRectangle(cornerRadius: s * 0.06).stroke(accentColor, lineWidth: max(1.1, s * 0.06)))
                        .frame(width: s * 0.28, height: s * 0.18)
                    Rectangle().fill(accentColor).frame(width: s * 0.08, height: max(1.1, s * 0.06))
                    RoundedRectangle(cornerRadius: s * 0.06).fill(Color.black)
                        .overlay(RoundedRectangle(cornerRadius: s * 0.06).stroke(accentColor, lineWidth: max(1.1, s * 0.06)))
                        .frame(width: s * 0.28, height: s * 0.18)
                }
                MouthSmile().stroke(accentColor, style: StrokeStyle(lineWidth: max(1.1, s * 0.065), lineCap: .round))
                    .frame(width: s * 0.20, height: s * 0.08)
            }

        case .sleepy:
            ZStack(alignment: .topTrailing) {
                VStack(spacing: s * 0.08) {
                    HStack(spacing: s * 0.18) {
                        Capsule().fill(accentColor.opacity(0.75)).frame(width: s * 0.20, height: s * 0.09)
                        Capsule().fill(accentColor.opacity(0.75)).frame(width: s * 0.20, height: s * 0.09)
                    }
                    Circle().stroke(accentColor.opacity(0.7), lineWidth: max(1.0, s * 0.055)).frame(width: s * 0.11, height: s * 0.11)
                }
                Text("z").font(.system(size: s * 0.22, weight: .bold, design: .rounded)).foregroundColor(accentColor.opacity(0.85))
                    .offset(x: s * 0.08, y: -s * 0.12)
            }

        case .shyBlush:
            VStack(spacing: s * 0.06) {
                HStack(spacing: s * 0.20) {
                    Circle().fill(accentColor).frame(width: s * 0.15, height: s * 0.15)
                    Circle().fill(accentColor).frame(width: s * 0.15, height: s * 0.15)
                }
                HStack(spacing: s * 0.10) {
                    Capsule().fill(blushPink.opacity(0.85)).frame(width: s * 0.15, height: s * 0.07)
                    Text("w").font(.system(size: s * 0.22, weight: .bold, design: .rounded)).foregroundColor(accentColor)
                    Capsule().fill(blushPink.opacity(0.85)).frame(width: s * 0.15, height: s * 0.07)
                }
            }

        case .catFace:
            VStack(spacing: s * 0.05) {
                HStack(spacing: s * 0.18) {
                    Circle().fill(accentColor).frame(width: s * 0.19, height: s * 0.19)
                    Circle().fill(accentColor).frame(width: s * 0.19, height: s * 0.19)
                }
                Text("ω").font(.system(size: s * 0.24, weight: .bold, design: .rounded)).foregroundColor(accentColor)
            }

        case .focusScan:
            VStack(spacing: s * 0.08) {
                HStack(spacing: s * 0.16) {
                    Capsule().fill(accentColor).frame(width: s * 0.22, height: s * 0.15)
                    Capsule().fill(accentColor).frame(width: s * 0.22, height: s * 0.15)
                }
                Capsule().fill(accentColor.opacity(0.6)).frame(width: s * 0.26, height: max(1.0, s * 0.05))
            }

        case .sweatDrop:
            ZStack(alignment: .topTrailing) {
                VStack(spacing: s * 0.07) {
                    HStack(spacing: s * 0.18) {
                        Capsule().fill(accentColor).frame(width: s * 0.18, height: s * 0.20)
                        Capsule().fill(accentColor).frame(width: s * 0.18, height: s * 0.20)
                    }
                    Capsule().fill(accentColor.opacity(0.85)).frame(width: s * 0.20, height: max(1.1, s * 0.06))
                }
                Image(systemName: "drop.fill")
                    .font(.system(size: s * 0.20))
                    .foregroundColor(tearBlue)
                    .offset(x: s * 0.14, y: -s * 0.08 + tearOffset * 0.5)
            }
        }
    }

    // MARK: - Mood-Specific Autonomous Expression Cycling

    private func expressionPool(for mood: RobotMood) -> [RobotExpression] {
        switch mood {
        case .overdue:
            return [.crying, .crying, .sobbing, .crying, .sweatDrop]
        case .error:
            return [.angryError, .dizzy, .surprised, .angryError]
        case .running:
            return [.focusScan, .thinking, .curious, .focusScan]
        case .success:
            return [.happySmile, .starry, .love, .wink]
        case .attention:
            return [.curious, .wink, .thinking, .sweatDrop, .catFace, .shyBlush, .surprised, .coolShades, .blinking, .happySmile]
        case .idle:
            return [.happySmile, .blinking, .curious, .catFace, .shyBlush, .wink, .coolShades, .sleepy, .starry, .love, .thinking]
        }
    }

    private func pickExpressionForMood(initial: Bool) {
        let pool = expressionPool(for: presentation.mood)
        let next = initial ? (pool.first ?? .curious) : (pool.randomElement() ?? .curious)
        withAnimation(.easeInOut(duration: 0.22)) {
            expression = next
        }
    }

    private func stepAnimation() {
        guard presentation.animateIdle else {
            glanceX = 0
            bounceY = 0
            tearOffset = 0
            return
        }

        // Change expression every 2–3 seconds so the robot feels vividly alive
        if tick % 2 == 0 {
            pickExpressionForMood(initial: false)
        }

        switch presentation.mood {
        case .overdue:
            // Sobbing tremble + falling tears
            withAnimation(.easeInOut(duration: 0.22)) {
                glanceX = (tick % 2 == 0) ? -1.0 : 1.0
                bounceY = (tick % 2 == 0) ? 0.8 : -0.4
                tearOffset = (tick % 2 == 0) ? 0.0 : 2.2
            }
        case .error:
            withAnimation(.easeInOut(duration: 0.16)) {
                glanceX = (tick % 2 == 0) ? -1.5 : 1.5
                bounceY = 0
            }
        case .running:
            withAnimation(.easeInOut(duration: 0.45)) {
                glanceX = (tick % 2 == 0) ? -2.2 : 2.2
                bounceY = 0
            }
        case .success:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
                glanceX = 0
                bounceY = (tick % 2 == 0) ? -1.5 : 0.4
            }
        case .attention, .idle:
            withAnimation(.easeInOut(duration: 0.32)) {
                glanceX = CGFloat([-2.0, 0.0, 2.0].randomElement() ?? 0.0)
                bounceY = CGFloat([-0.7, 0.0, 0.5].randomElement() ?? 0.0)
                tearOffset = (tick % 2 == 0) ? 0.0 : 1.2
            }
        }
    }
}

private struct ArcSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY))
        return p
    }
}

private struct MouthSmile: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY))
        return p
    }
}

private struct SadArc: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY))
        return p
    }
}
