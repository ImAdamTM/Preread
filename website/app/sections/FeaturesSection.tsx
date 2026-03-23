import { Reveal } from "../components/Reveal";
import { ScrollScale } from "../components/ScrollScale";
import { PhoneFrame } from "../components/PhoneFrame";
import { PhoneCycler } from "../components/PhoneCycler";
import { WidgetComposition } from "../components/WidgetComposition";
import { theme as t } from "../components/theme";

function ImagePhone({
  src,
  alt,
  offsetMobile,
}: {
  src: string;
  alt: string;
  offsetMobile?: string;
}) {
  return (
    <PhoneFrame className="w-full max-w-[280px]">
      <img
        src={src}
        alt={alt}
        className={`w-full h-auto block ${offsetMobile ? "phone-offset-mobile" : ""}`}
        style={
          {
            aspectRatio: "1260 / 2736",
            "--phone-offset": offsetMobile,
          } as React.CSSProperties
        }
      />
    </PhoneFrame>
  );
}

const features = [
  {
    title: (
      <>
        Stumble into <span className="gradient-text">new interests.</span>
      </>
    ),
    desc: "Browse 500+ sources across world news, science, food, travel, gaming, DIY, celebrity culture, architecture, from 55+ topics and countries. Your next favourite publication is one tap away.",
    Phone: () => (
      <ImagePhone src="/assets/discovery.webp" alt="Browse topics" />
    ),
    reverse: false,
    noClip: false,
  },
  {
    title: (
      <>
        A <span className="gradient-text">reading-first</span> experience.
      </>
    ),
    desc: "Clean typography, customisable fonts, adjustable text sizes. Just you and the article. Dark mode or light, the reader adapts.",
    Phone: () => (
      <PhoneCycler
        images={["/assets/article.webp", "/assets/article-light.webp"]}
        className="w-full max-w-[280px]"
      />
    ),
    reverse: true,
    noClip: false,
  },
  {
    title: (
      <>
        No saving <span className="gradient-text">required.</span>
      </>
    ),
    desc: "Most reading apps make you save articles one at a time. Preread works in the background, so your reading list is always full without you lifting a finger.",
    Phone: () => (
      <ImagePhone
        src="/assets/settings.webp"
        alt="Settings"
        offsetMobile="-46%"
      />
    ),
    reverse: false,
    noClip: false,
  },
  {
    title: (
      <>
        Widgets. Watch. Siri. <span className="gradient-text">Share.</span>
      </>
    ),
    desc: "Glance at articles from your home screen. Read on your wrist. Share any URL to Preread from Safari. Ask Siri to open your favourite source.",
    Phone: WidgetComposition,
    reverse: true,
    noClip: true,
  },
];

export function FeaturesSection() {
  return (
    <section className="py-32 px-6">
      <div className="max-w-[1100px] mx-auto space-y-32">
        {features.map((feature, i) => (
          <div
            key={i}
            className="grid grid-cols-1 md:grid-cols-2 gap-8 md:gap-20 items-center"
          >
            <ScrollScale
              className={`order-2 ${feature.reverse ? "md:order-1" : "md:order-1"} flex justify-center ${feature.reverse ? "" : "md:justify-end"}`}
              x={{
                default: [0, 0],
                md: ["-50%", "0%"],
              }}
              y={[30, 0]}
            >
              <div
                className={
                  feature.noClip
                    ? "w-full max-w-[280px]"
                    : "phone-clip-mobile w-full max-w-[280px]"
                }
              >
                <feature.Phone />
              </div>
            </ScrollScale>
            <Reveal
              className={`order-1 ${feature.reverse ? "md:order-2" : "md:order-2"} text-center md:text-left`}
              delay={0.1}
            >
              <h2 className="text-3xl md:text-4xl font-heading font-bold leading-tight mb-4">
                {feature.title}
              </h2>
              <p
                className="text-lg leading-relaxed"
                style={{ color: t.secondary }}
              >
                {feature.desc}
              </p>
            </Reveal>
          </div>
        ))}
      </div>
    </section>
  );
}
