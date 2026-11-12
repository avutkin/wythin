import SwiftUI

// MARK: - SplashView

/// Full-screen splash shown on launch.
///
/// Opens on pure black and reveals in three beats — the quote first, then the
/// skip hint, then the brand — so the first thing the eye lands on is the
/// words, not the logo. The app is already loading behind it; the whole
/// sequence is skippable from the moment the hint appears.
struct SplashView: View {

    let onFinished: () -> Void

    @State private var opacity:      Double  = 1   // whole-view fade on dismiss
    @State private var quoteOpacity: Double  = 0
    @State private var quoteOffset:  CGFloat = 14  // slight rise as it lands
    @State private var skipOpacity:  Double  = 0
    @State private var brandOpacity: Double  = 0
    @State private var quote = quotes.randomElement()!

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.8)) { opacity = 0 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { onFinished() }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The quote is centred on the SCREEN, not in the space left over
            // by the brand — so it reads as the subject of the composition,
            // and its position doesn't shift when the brand fades in.
            quoteBlock
                .opacity(quoteOpacity)
                .offset(y: quoteOffset)

            VStack {
                brandBlock
                    .opacity(brandOpacity)
                Spacer(minLength: 0)
            }

            VStack {
                Spacer(minLength: 0)
                skipButton
                    .opacity(skipOpacity)
            }
        }
        .opacity(opacity)
        // The whole screen is tappable to skip; the chevron just makes that
        // discoverable.
        .contentShape(Rectangle())
        .onTapGesture { if skipOpacity > 0 { dismiss() } }
        .onAppear {
            withAnimation(.easeOut(duration: 1.2).delay(0.25)) {
                quoteOpacity = 1
                quoteOffset  = 0
            }
            withAnimation(.easeIn(duration: 0.6).delay(1.7))  { skipOpacity  = 1 }
            withAnimation(.easeIn(duration: 0.9).delay(2.1))  { brandOpacity = 1 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.2) { dismiss() }
        }
    }

    // MARK: - Pieces

    /// Last to arrive, and deliberately quiet — the words lead, the mark follows.
    private var brandBlock: some View {
        VStack(spacing: 14) {
            Image("WythinLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .foregroundStyle(Theme.text)

            VStack(spacing: 8) {
                Text("wythin")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .tracking(6)

                Text(LocalizedCopy.text("Discover the Universe Inside You"))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.text.opacity(0.42))
                    .tracking(1.4)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.top, 56)
    }

    private var quoteBlock: some View {
        VStack(spacing: 0) {
            Text(quote.text)
                .font(.system(size: 19, weight: .light, design: .serif))
                .foregroundStyle(Theme.text.opacity(0.92))
                .multilineTextAlignment(.center)
                .lineSpacing(9)
                .padding(.horizontal, 40)

            Spacer().frame(height: 30)

            Rectangle()
                .fill(Theme.text.opacity(0.18))
                .frame(width: 24, height: 0.5)

            Spacer().frame(height: 22)

            Text(quote.author.uppercased())
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.text.opacity(0.4))
                .tracking(4)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 48)
        }
    }

    /// White, not accent — this is a way out, not a call to action.
    private var skipButton: some View {
        Button(action: dismiss) {
            HStack(spacing: 8) {
                Rectangle()
                    .frame(width: 28, height: 0.5)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(Theme.text.opacity(0.45))
            .contentShape(Rectangle())
            .padding(12)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 44)
    }

    // MARK: - Quote Library

    private struct Quote {
        let text:   String
        let author: String
    }

    private static let quotes: [Quote] = [

        // Ancient wisdom
        Quote(
            text:   LocalizedCopy.text("When the breath wanders, the mind also is unsteady. But when the breath is calmed, the mind too will be still."),
            author: LocalizedCopy.text("Hatha Yoga Pradipika")
        ),
        Quote(
            text:   LocalizedCopy.text("Breath is the king of mind."),
            author: LocalizedCopy.text("B.K.S. Iyengar")
        ),
        Quote(
            text:   LocalizedCopy.text("For breath is life, and if you breathe well you will live long on earth."),
            author: LocalizedCopy.text("Sanskrit proverb")
        ),
        Quote(
            text:   LocalizedCopy.text("Control of the breath is the supreme form of self-discipline."),
            author: LocalizedCopy.text("Patanjali, Yoga Sutras")
        ),
        Quote(
            text:   LocalizedCopy.text("There is one way of breathing that is shameful and constricted. Then there is another way — a breath of love that takes you all the way to infinity."),
            author: LocalizedCopy.text("Rumi")
        ),
        Quote(
            text:   LocalizedCopy.text("Breathing correctly is the foundation of any practice of self-cultivation."),
            author: LocalizedCopy.text("Zhuangzi")
        ),

        // Gorakh Bodh
        Quote(
            text:   LocalizedCopy.text("Inhalation brings the sound 'Sah', exhalation carries the sound 'Ham'. So-Ham is the breath's own mantra."),
            author: LocalizedCopy.text("Gorakh Bodh")
        ),
        Quote(
            text:   LocalizedCopy.text("They who reverse the breath, tame the vital air, and still the mind — they alone know the Self."),
            author: LocalizedCopy.text("Gorakh Bodh")
        ),
        Quote(
            text:   LocalizedCopy.text("Prana flows through the median channel when the breath is refined and the mind made quiet."),
            author: LocalizedCopy.text("Gorakh Bodh")
        ),
        Quote(
            text:   LocalizedCopy.text("Listen to the inner sound that arises beyond all breath — the unstruck note that echoes in silence."),
            author: LocalizedCopy.text("Gorakh Bodh")
        ),

        // Modern teachers
        Quote(
            text:   LocalizedCopy.text("Breath is the bridge which connects life to consciousness, which unites your body to your thoughts."),
            author: LocalizedCopy.text("Thích Nhất Hạnh")
        ),
        Quote(
            text:   LocalizedCopy.text("Feelings come and go like clouds in a windy sky. Conscious breathing is my anchor."),
            author: LocalizedCopy.text("Thích Nhất Hạnh")
        ),
        Quote(
            text:   LocalizedCopy.text("The quality of our breath expresses our inner feelings."),
            author: LocalizedCopy.text("T.K.V. Desikachar")
        ),
        Quote(
            text:   LocalizedCopy.text("Breathe in deeply to bring your mind home to your body."),
            author: LocalizedCopy.text("Thích Nhất Hạnh")
        ),
        Quote(
            text:   LocalizedCopy.text("In the practice of meditation, the breath is your anchor, your home, the place you can always return to."),
            author: LocalizedCopy.text("Jon Kabat-Zinn")
        ),
        Quote(
            text:   LocalizedCopy.text("The present moment always will have been. Come back to the breath and it is always here."),
            author: LocalizedCopy.text("Jon Kabat-Zinn")
        ),

        // Science & medicine
        Quote(
            text:   LocalizedCopy.text("No matter what you eat, how much you exercise, or how resilient your genes are, none of it matters unless you're breathing correctly."),
            author: LocalizedCopy.text("James Nestor, Breath")
        ),
        Quote(
            text:   LocalizedCopy.text("Breath is the most powerful drug we have. Learning to use it is one of the greatest gifts you can give yourself."),
            author: LocalizedCopy.text("Andrew Weil")
        ),
        Quote(
            text:   LocalizedCopy.text("If I had to limit my advice on healthier living to just one tip, it would be simply to breathe properly."),
            author: LocalizedCopy.text("Andrew Weil")
        ),
        Quote(
            text:   LocalizedCopy.text("The breath is always here. It never leaves you. And you can always come back to it."),
            author: LocalizedCopy.text("Wim Hof")
        ),
        Quote(
            text:   LocalizedCopy.text("Breathing is the first act of life and the last. Our very life depends on it."),
            author: LocalizedCopy.text("Joseph Pilates")
        ),

        // Philosophy & poetry
        Quote(
            text:   LocalizedCopy.text("When you own your breath, nobody can steal your peace."),
            author: LocalizedCopy.text("Unknown")
        ),
        Quote(
            text:   LocalizedCopy.text("Inhale the future, exhale the past."),
            author: LocalizedCopy.text("Unknown")
        ),
        Quote(
            text:   LocalizedCopy.text("Breathe deeply, until sweet air extinguishes the burn of fear in your lungs and every breath is a beautiful refusal to become anything less than infinite."),
            author: LocalizedCopy.text("D. Antoinette Foy")
        ),
        Quote(
            text:   LocalizedCopy.text("With every breath, I plant the seeds of devotion. I am a farmer of the heart."),
            author: LocalizedCopy.text("Rumi")
        ),
        Quote(
            text:   LocalizedCopy.text("Breathing in, I calm my body and mind. Breathing out, I smile. Dwelling in the present moment, I know this is the only moment."),
            author: LocalizedCopy.text("Thích Nhất Hạnh")
        ),
        Quote(
            text:   LocalizedCopy.text("The rhythm of the body, the melody of the mind, and the harmony of the soul create the symphony of life."),
            author: LocalizedCopy.text("B.K.S. Iyengar")
        ),
        Quote(
            text:   LocalizedCopy.text("Perhaps the most important thing we bring to another person is the silence in us. Not the sort of silence that is empty, but the kind that is a willingness to witness."),
            author: LocalizedCopy.text("Rachel Naomi Remen")
        ),
        Quote(
            text:   LocalizedCopy.text("Life is not measured by the number of breaths we take, but by the moments that take our breath away."),
            author: LocalizedCopy.text("Maya Angelou")
        ),
        Quote(
            text:   LocalizedCopy.text("In the middle of difficulty lies opportunity — find it in the breath."),
            author: LocalizedCopy.text("Albert Einstein")
        ),
        Quote(
            text:   LocalizedCopy.text("Smile, breathe, and go slowly."),
            author: LocalizedCopy.text("Thích Nhất Hạnh")
        ),
    ]
}
