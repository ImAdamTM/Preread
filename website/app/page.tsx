import { Header } from "./sections/Header";
import { HeroSection } from "./sections/HeroSection";
import { ManifestoSection } from "./sections/ManifestoSection";
import { HowItWorksSection } from "./sections/HowItWorksSection";
import { FeaturesSection } from "./sections/FeaturesSection";
import { OfflineSection } from "./sections/OfflineSection";
import { DownloadSection } from "./sections/DownloadSection";
import { Footer } from "./sections/Footer";

export default function Home() {
  return (
    <>
      <Header />
      <main>
        <HeroSection />
        <ManifestoSection />
        <HowItWorksSection />
        <FeaturesSection />
        <OfflineSection />
        <DownloadSection />
      </main>
      <Footer />
    </>
  );
}
