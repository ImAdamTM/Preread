import { Reveal } from "../components/Reveal";
import { ScrollScale } from "../components/ScrollScale";
import { PhoneFrame } from "../components/PhoneFrame";
import { theme as t } from "../components/theme";

const steps = [
  {
    num: "1",
    title: "Add the sites you love.",
    desc: "Browse 55+ topics or paste any URL. Preread finds the articles for you.",
    image: "/assets/discovery.webp",
  },
  {
    num: "2",
    title: "We make them ready.",
    desc: "Articles are prepared automatically in the background. No saving required.",
    image: "/assets/home.webp",
  },
  {
    num: "3",
    title: "Read anywhere. Even offline.",
    desc: "On the train, on a plane, or just on the sofa. Your articles are always there.",
    image: "/assets/article.webp",
  },
];

export function HowItWorksSection() {
  return (
    <section className="py-32 px-6 bg-[#060609]">
      <div className="max-w-[1100px] mx-auto">
        <Reveal>
          <p
            className="text-sm font-medium uppercase tracking-widest text-center mb-16"
            style={{ color: t.secondary }}
          >
            How it works
          </p>
        </Reveal>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-16 md:gap-8 lg:gap-12">
          {steps.map((step, i) => (
            <ScrollScale
              key={step.num}
              y={{ default: [100 * (i + 1), 0], md: [120 * (i + 1), 0] }}
              className={`flex flex-col items-center text-center ${step.num === "2" ? "md:mt-12" : step.num === "3" ? "md:mt-24" : ""}`}
            >
              <span className="font-heading font-bold text-6xl md:text-7xl gradient-text mb-4">
                {step.num}
              </span>
              <h3 className="text-2xl font-heading font-bold mb-3">
                {step.title}
              </h3>
              <p
                className="text-lg mb-10 min-h-[56px]"
                style={{ color: t.secondary }}
              >
                {step.desc}
              </p>
              <PhoneFrame className="w-full max-w-[260px]">
                <img
                  src={step.image}
                  alt={step.title}
                  className="w-full h-auto block"
                  style={{ aspectRatio: "1260 / 2736" }}
                />
              </PhoneFrame>
            </ScrollScale>
          ))}
        </div>
      </div>
    </section>
  );
}
