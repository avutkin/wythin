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

                Text("Discover the Universe Inside You")
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
            text:   "When the breath wanders, the mind also is unsteady. But when the breath is calmed, the mind too will be still.",
            author: "Hatha Yoga Pradipika"
        ),
        Quote(
            text:   "Breath is the king of mind.",
            author: "B.K.S. Iyengar"
        ),
        Quote(
            text:   "For breath is life, and if you breathe well you will live long on earth.",
            author: "Sanskrit proverb"
        ),
        Quote(
            text:   "Control of the breath is the supreme form of self-discipline.",
            author: "Patanjali, Yoga Sutras"
        ),
        Quote(
            text:   "There is one way of breathing that is shameful and constricted. Then there is another way — a breath of love that takes you all the way to infinity.",
            author: "Rumi"
        ),
        Quote(
            text:   "Breathing correctly is the foundation of any practice of self-cultivation.",
            author: "Zhuangzi"
        ),

        // Gorakh Bodh
        Quote(
            text:   "Inhalation brings the sound 'Sah', exhalation carries the sound 'Ham'. So-Ham is the breath's own mantra.",
            author: "Gorakh Bodh"
        ),
        Quote(
            text:   "They who reverse the breath, tame the vital air, and still the mind — they alone know the Self.",
            author: "Gorakh Bodh"
        ),
        Quote(
            text:   "Prana flows through the median channel when the breath is refined and the mind made quiet.",
            author: "Gorakh Bodh"
        ),
        Quote(
            text:   "Listen to the inner sound that arises beyond all breath — the unstruck note that echoes in silence.",
            author: "Gorakh Bodh"
        ),

        // Modern teachers
        Quote(
            text:   "Breath is the bridge which connects life to consciousness, which unites your body to your thoughts.",
            author: "Thích Nhất Hạnh"
        ),
        Quote(
            text:   "Feelings come and go like clouds in a windy sky. Conscious breathing is my anchor.",
            author: "Thích Nhất Hạnh"
        ),
        Quote(
            text:   "The quality of our breath expresses our inner feelings.",
            author: "T.K.V. Desikachar"
        ),
        Quote(
            text:   "Breathe in deeply to bring your mind home to your body.",
            author: "Thích Nhất Hạnh"
        ),
        Quote(
            text:   "In the practice of meditation, the breath is your anchor, your home, the place you can always return to.",
            author: "Jon Kabat-Zinn"
        ),
        Quote(
            text:   "The present moment always will have been. Come back to the breath and it is always here.",
            author: "Jon Kabat-Zinn"
        ),

        // Science & medicine
        Quote(
            text:   "No matter what you eat, how much you exercise, or how resilient your genes are, none of it matters unless you're breathing correctly.",
            author: "James Nestor, Breath"
        ),
        Quote(
            text:   "Breath is the most powerful drug we have. Learning to use it is one of the greatest gifts you can give yourself.",
            author: "Andrew Weil"
        ),
        Quote(
            text:   "If I had to limit my advice on healthier living to just one tip, it would be simply to breathe properly.",
            author: "Andrew Weil"
        ),
        Quote(
            text:   "The breath is always here. It never leaves you. And you can always come back to it.",
            author: "Wim Hof"
        ),
        Quote(
            text:   "Breathing is the first act of life and the last. Our very life depends on it.",
            author: "Joseph Pilates"
        ),

        // Philosophy & poetry
        Quote(
            text:   "When you own your breath, nobody can steal your peace.",
            author: "Unknown"
        ),
        Quote(
            text:   "Inhale the future, exhale the past.",
            author: "Unknown"
        ),
        Quote(
            text:   "Breathe deeply, until sweet air extinguishes the burn of fear in your lungs and every breath is a beautiful refusal to become anything less than infinite.",
            author: "D. Antoinette Foy"
        ),
        Quote(
            text:   "With every breath, I plant the seeds of devotion. I am a farmer of the heart.",
            author: "Rumi"
        ),
        Quote(
            text:   "Breathing in, I calm my body and mind. Breathing out, I smile. Dwelling in the present moment, I know this is the only moment.",
            author: "Thích Nhất Hạnh"
        ),
        Quote(
            text:   "The rhythm of the body, the melody of the mind, and the harmony of the soul create the symphony of life.",
            author: "B.K.S. Iyengar"
        ),
        Quote(
            text:   "Perhaps the most important thing we bring to another person is the silence in us. Not the sort of silence that is empty, but the kind that is a willingness to witness.",
            author: "Rachel Naomi Remen"
        ),
        Quote(
            text:   "Life is not measured by the number of breaths we take, but by the moments that take our breath away.",
            author: "Maya Angelou"
        ),
        Quote(
            text:   "In the middle of difficulty lies opportunity — find it in the breath.",
            author: "Albert Einstein"
        ),
        Quote(
            text:   "Smile, breathe, and go slowly.",
            author: "Thích Nhất Hạnh"
        ),
    ]
}
