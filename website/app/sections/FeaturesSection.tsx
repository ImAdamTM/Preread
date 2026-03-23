import { Reveal } from "../components/Reveal";
import { ScrollScale } from "../components/ScrollScale";
import { PhoneFrame } from "../components/PhoneFrame";
import { PhoneCycler } from "../components/PhoneCycler";
import { WidgetComposition } from "../components/WidgetComposition";
import { theme as t } from "../components/theme";

function ImagePhone({ src, alt }: { src: string; alt: string }) {
  return (
    <PhoneFrame className="w-full max-w-[280px]">
      <img
        src={src}
        alt={alt}
        className="w-full h-auto block"
        style={{ aspectRatio: "1260 / 2736" }}
      />
    </PhoneFrame>
  );
}

const features = [
  {
    title: <>Stumble into <span className="gradient-text">new interests.</span></>,
    desc: "Browse 500+ sources across world news, science, food, travel, gaming, DIY, celebrity culture, architecture, and 55+ more topics and countries. Your next favourite publication is one tap away.",
    Phone: () => <ImagePhone src="/assets/discovery.webp" alt="Browse topics" />,
    reverse: false,
  },
  {
    title: <>A <span className="gradient-text">reading-first</span> experience.</>,
    desc: "Clean typography, customisable fonts, adjustable text sizes. Just you and the article. Dark mode or light, the reader adapts.",
    Phone: () => <PhoneCycler images={["/assets/article.webp", "/assets/article-light.webp"]} className="w-full max-w-[280px]" />,
    reverse: true,
  },
  {
    title: <>No saving <span className="gradient-text">required.</span></>,
    desc: "Most reading apps make you save articles one at a time. Preread works in the background, so your reading list is always full without you lifting a finger.",
    Phone: () => <ImagePhone src="/assets/settings.webp" alt="Settings" />,
    reverse: false,
  },
  {
    title: <>Widgets. Watch. Siri. <span className="gradient-text">Share.</span></>,
    desc: "Glance at articles from your home screen. Read on your wrist. Share any URL to Preread from Safari. Ask Siri to open your favourite source.",
    Phone: WidgetComposition,
    reverse: true,
  },
];

export function FeaturesSection() {
  return (
    <section className="py-32 px-6">
      <div className="max-w-[1100px] mx-auto space-y-32">
        {features.map((feature, i) => (
          <div
            key={i}
            className="grid grid-cols-1 md:grid-cols-2 gap-12 md:gap-20 items-center"
          >
            <ScrollScale
              className={`${feature.reverse ? "order-1" : "order-2 md:order-1"} flex justify-center ${feature.reverse ? "" : "md:justify-end"}`}
              x={{
                default: [0, 0],
                md: ["-50%", "0%"],
              }}
              y={[30, 0]}
            >
              <feature.Phone />
            </ScrollScale>
            <Reveal
              className={feature.reverse ? "order-2" : "order-1 md:order-2"}
              delay={0.1}
            >
              <h2 className="text-3xl md:text-4xl font-heading font-bold leading-tight mb-4">
                {feature.title}
              </h2>
              <p className="text-lg leading-relaxed" style={{ color: t.secondary }}>
                {feature.desc}
              </p>
            </Reveal>
          </div>
        ))}
      </div>
    </section>
  );
}
