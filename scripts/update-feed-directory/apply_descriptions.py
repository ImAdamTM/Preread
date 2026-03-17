#!/usr/bin/env python3
"""Apply curated refined descriptions to feeds in categories/."""

import json
from pathlib import Path

# Manual overrides: name -> description
# These fix cases where both current and OG are bad/missing/spammy
OVERRIDES = {
    "500px": "Photography community and inspiration",
    "8 Columnas": "Periodismo digital de México",
    "A Beautiful Mess": "Crafts, home decor, and recipes",
    "A List Apart": "Articles for people who make websites",
    "ELLE": "Fashion, beauty, celebrity, and culture",
    "Code Wall": "Web development and programming",
    "Daily Maverick": "South African investigative journalism",
    "Brad Feld": "Venture capital and startup insights",
    "Feld Thoughts": "Venture capital and startup insights",
    "News24 Top Stories": "South African news and current affairs",
    "Apple Newsroom": "Official Apple news and product announcements",
    "GazetaPrawna.pl": "Polskie wiadomości prawne, gospodarcze i polityczne",
    "L'essentiel": "Actualités du Luxembourg et de la Grande Région en temps réel",
    "Nigerian News Latest": "Latest news from Nigeria",
    "Top Gear": "The Philippines' best online source for cars and the automotive industry",
    "RSS di - ANSA.it": "Agenzia di stampa italiana con notizie dall'Italia e dal mondo",
    "Sink In": "Tech and travel blog",
    "ReadWrite": "Technology news, trends, and analysis",
    "Use Your Loaf": "iOS development news and tips",
    "SwiftRocks": "How Swift works under the hood, plus iOS tips and tricks",
    "Overreacted": "Personal blog by Dan Abramov on React and JavaScript",
    "Six Colors": "Apple news and commentary by Jason Snell",
    "Under the Radar": "Independent iOS and Mac app development",
    "The Moscow Times": "Independent English-language news from Russia",
    "The News International - Pakistan": "Pakistan's leading English-language newspaper",
    "All: BreakingNews.ie": "Ireland's breaking news, sport, and weather",
    "Portada // expansion": "Noticias económicas, mercados y opinión de España",
    "kalerkantho Kantho": "বাংলাদেশের শীর্ষ অনলাইন সংবাদপত্র",
    "POPSUGAR Fashion": "Fashion, beauty, and style trends",
    "Facebook Engineering": "Engineering at Meta",
    "Sports": "Sports news, scores, and fantasy games from Yahoo",
    "Penny Arcade": "Gaming webcomic and commentary by Mike Krahulik and Jerry Holkins",
    "Nigerian Bulletin": "Nigerian news, articles, and trending stories",
    "Il Mattino Web": "Quotidiano di Napoli con notizie di cronaca, sport e cultura",
    "Panorama": "Settimanale italiano di attualità, politica e cultura",
    "INQUIRER.net": "Philippine news for Filipinos",
    "Pitchfork": "The most trusted voice in music",
    "Milan News": "Testata giornalistica dedicata al Milan",
    "Design Milk": "Modern design across architecture, interiors, art, and technology",
    "ઈન્ડિયા | દિવ્ય ભાસ્કર": "ગુજરાતી ભાષામાં ભારત અને વિશ્વના સમાચાર",
    "Android Central": "Android news, reviews, and how-tos",
    "Ouest-France": "Premier quotidien français d'information régionale et nationale",
    "Axios": "Smart, efficient news coverage of politics, business, and technology",
    "Le Huffington Post": "Actualités, opinions et tendances en France et dans le monde",
    "Paris Star": "Paris news and culture",
    "The Nation": "Progressive American journalism on politics and culture",
    "Software Engineering Daily": "Daily interviews about software engineering topics",
    "Playbook": "The unofficial guide to official Washington",
    "España": "Noticias de España",
    "Joy the Baker": "Baking recipes and kitchen inspiration",
    "Scripting News": "Dave Winer's blog on technology, media, and the open web",
    "smitten kitchen": "Fearless cooking from a tiny NYC kitchen",
    "The Bloggess": "Humor and personal essays by Jenny Lawson",
    "The Ancient Gaming Noob": "MMO and PC gaming blog",
    "Hacker News": "Links for the intellectually curious, ranked by readers",
    "Hacker News: Front Page": "Top stories from Hacker News",
    "Google News": "Comprehensive news aggregation from Google",
    "CSS-Tricks": "Tips, tricks, and techniques on CSS and web development",
    "inessential.com": "Brent Simmons's weblog on Mac and iOS development",
    "David Walsh Blog": "Tutorials on JavaScript, HTML5, CSS, and web development",
    "The Daily WTF": "Curious perversions in information technology",
    "Smashing Magazine": "Articles and tutorials for web designers and developers",
    "Eurogamer.net": "Video game news, reviews, and features",
    "Droid Life": "Opinionated Android news and reviews",
    "Ole Begemann": "iOS and Swift development blog",
    "Jake Wharton": "Android and Kotlin development",
    "Handstand Sam": "Android and web development",
    "Fabisevi.ch": "iOS development blog",
    "Martin Fowler": "Software architecture and development practices",
    "Hacking with Swift": "Free Swift tutorials for iOS development",
    "Code as Craft": "The engineering blog from Etsy",
    "How Sweet Eats": "Food blog with recipes for people who love to eat",
    "Shutterbean": "Food, photography, and inspiration",
    "Bring a Trailer": "Online auction platform for enthusiast vehicles",
    "Kitchn": "Inspiring cooks, nourishing homes",
    "Nomadic Matt's Travel Site": "Budget travel tips and destination guides",
    "Afford Anything": "Personal finance and building a life of freedom",
    "Inc.com": "Resources and advice for entrepreneurs and business leaders",
    "Moneyweb": "South African business, financial, and investment news",
    "Financial Post": "Canadian business, financial, and investment news",
    "Ain't It Cool News Feed": "Movie, TV, and comic book news and reviews",
    "Who What Wear": "Fashion trends, outfit ideas, and style inspiration",
    "Fashionista": "Fashion industry news, trends, and career advice",
    "Kotaku": "Gaming news, reviews, and culture",
    "GameSpot": "Video game news, reviews, trailers, and walkthroughs",
    "hongkongnews.net latest rss headlines": "Hong Kong news headlines",
    "National Post": "Canadian news, politics, and opinion",
    "https://www.rp.pl": "Rzeczpospolita — polskie wiadomości i publicystyka",
    "Duct Tape Marketing": "Small business marketing tips and strategies",
    "Libero Quotidiano": "Quotidiano italiano di notizie e opinione",
    "Home Page": "Indian business, markets, and economic news",
    "Current PH": "Latest Philippine breaking news and stories",
    "AppleInsider News": "Apple news, rumors, reviews, and deals",
    "Google Developers Blog": "News and updates for Google developers",
    "JetBrains Blog": "Developer tools, tips, and IDE updates from JetBrains",
    "JetBrains News | JetBrains Blog": "News and announcements from JetBrains",
    "Joe Birch": "Android, Flutter, and Google Assistant development",
    "Dan Lew Codes": "Android development tips and insights",
    "Public Object": "Jesse Wilson on programming",
    "World & Nation": "Nation and world news from the Los Angeles Times",
    "World News": "Yahoo World News coverage",
    "The Guardian": "The latest news, comment, and analysis from The Guardian",
    "Coding Horror": "Programming and human factors by Jeff Atwood",
    "Nintendo": "Official Nintendo news, game announcements, and updates",
    "Nintendo Life": "Nintendo news, reviews, and features",
    "Xbox's Major Nelson": "Xbox news and updates direct from Microsoft",
    "BD24Live.com": "বাংলাদেশের অনলাইন সংবাদ",
    "IOL section feed for News": "South African news from Independent Media",
    "Mexico News Daily": "English-language news about Mexico",
    "Toronto Sun": "Toronto news, sports, and entertainment",
    "The Province": "Vancouver and BC news, sports, and headlines",
    "Ottawa Citizen": "Ottawa news, sports, and headlines",
    "Brisbane Times": "Brisbane and Queensland news",
    "Sky News": "Breaking news from the UK and around the world",
    "Daily Mail": "Breaking news, showbiz, sport, and entertainment from the UK",
    "Macworld.com": "Apple news, reviews, tips, and buying advice",
    "NN/g latest articles and announcements": "UX research and design best practices from Nielsen Norman Group",
    "Crazy Programmer": "Programming tutorials and resources",
    "The Crazy Programmer": "Programming tutorials and resources",
    "FashionBeans": "Men's fashion and style guide",
    "Fashionista": "Fashion industry news, beauty, and style",
    "EDM.com": "Electronic dance music news, downloads, and artist interviews",
    "Myanmar Gazette": "Myanmar news and current affairs",
    "JUST™ Creative": "Graphic design and branding resources",
    "AndrewGuys": "Android news and opinion",
    "AndroidGuys": "Android news and opinion",
    "Light Stalking": "Photography tips and inspiration",
    "Escapist Magazine": "Video game news, reviews, and culture",
    "Andrew Chen": "Essays on tech startups, growth, and network effects",
    "Metal Injection": "Heavy metal news, music, and videos",
    "Music Business Worldwide": "News and analysis for the global music industry",
    "Indie Games Plus": "Creative, personal, and passionate indie digital experiences",
    "Inhabitat": "Green design, innovation, and clean technology",
    "Doityourself.com": "DIY home improvement projects and repair guides",
    "Premium Times Nigeria": "Nigeria's leading independent online newspaper",
    "Digital Photography School": "Photography tips and tutorials for all skill levels",
    "The Independent": "UK and world news, politics, and opinion",
    "BBC News": "Science and environment news from BBC",
    "BBC News - India": "India news from BBC",
    "BBC News - World": "World news from BBC",
    "BBC Sport - Cricket": "Cricket news, scores, and results from BBC Sport",
    "BBC Sport - Sport": "Sports news, scores, and analysis from BBC Sport",
    "BBC Sport - Tennis": "Tennis news, scores, and results from BBC Sport",
    "News Blog": "Technology, travel, sports, health, and entertainment news",
    "peRFect Tennis": "Tennis news and analysis",
    "Andrew Chen": "Essays on startups, growth, and network effects",
    "Lo último en Vanguardia MX": "Noticias de Coahuila, México y el mundo",
    "PerthNow": "Western Australian and Australian news",
    "philstar.com - RSS Headlines": "Philippine news for the Filipino global community",
    "GMA News Online / News": "Philippine news from GMA Network",
}

# Names where we should prefer the current description over OG
PREFER_CURRENT = {
    "101 Cookbooks", "30 For 30 Podcasts", "A year of reading the world",
    "Accidental Tech Podcast", "Analog(ue)", "Bike EXIF",
    "Car Body Design", "Chocolate & Zucchini", "Cracked: All Posts",
    "Canberra Times", "Deccan Chronicle",
    "EL PAÍS: el periódico global", "Fanpage",
    "Free Press Journal", "Hackaday",
    "Hacking with Swift", "I Can Has Cheezburger?",
    "India News", "The Truth About Cars",
    "Love and Olive Oil", "MacStories",
    "Makeup and Beauty Blog", "Netflix TechBlog",
    "OS X Daily", "The Architect's Newspaper",
    "Autocar India", "Autocar RSS Feed",
    "Alberto De Bortoli", "Skinnytaste", "SwiftLee",
    "Interaksyon", "The A.V. Club", "Kirkus Reviews",
    "The FAIL Blog", "FAIL Blog",
    "Сanberra Times", "Canberra Times",
    "le monde", "IrishExaminer.com",
    "Space.com",
    "UX Collective - Medium",
    "PC Gamer",
    "Ars Technica",
    "Hanselminutes with Scott Hanselman",
    "NME",
    "IrishCentral.com",
    "Legit.ng",
    "Rolling Stone",
    "Scott Hanselman's Blog",
    "The Atlantic",
    "Times of India",
    "Wired",
    "Информационное агентство УНИАН",
    "Daring Fireball",
    "IGN",
    "IKEA Hackers",
    "Mashable",
    "The Verge",
    "International: Top News And Analysis",
    "CNBC International",
}


def pick_best(name, current, og):
    """Pick the best description, preferring concise and descriptive."""
    # Manual override
    if name in OVERRIDES:
        return OVERRIDES[name]

    # Prefer current for some feeds
    if name in PREFER_CURRENT and current and len(current) > 10:
        desc = current
    elif og and len(og) > 15 and not any(bad in og.lower() for bad in [
        "bonanza", "gambling", "casino", "slot", "suspect believed",
        "get each month", "responsive blogger", "shah code exporters",
        "brad feld", "bruno rocha", "latest updates read my",
        "kicked off celebrations",
    ]):
        desc = og
    elif current and len(current) > 5:
        desc = current
    else:
        desc = og or current or ""

    # Clean up
    desc = desc.strip()
    for junk in [
        "This feed is for non commercial use.",
        "FOR PERSONAL USE ONLY",
        "Content Copyright",
        "Default RSS Feed",
        " - Medium",
        "Kinja RSS",
    ]:
        desc = desc.replace(junk, "").strip()

    desc = " ".join(desc.split())

    # Truncate at ~120 chars at word boundary
    if len(desc) > 120:
        t = desc[:120]
        s = t.rfind(" ")
        if s > 60:
            t = t[:s]
        desc = t.rstrip(".,;:- ")

    desc = desc.rstrip(".")

    return desc


def main():
    base = Path(__file__).parent

    import re

    def slugify(name: str) -> str:
        s = name.lower()
        s = re.sub(r"[^a-z0-9\s-]", "", s)
        s = re.sub(r"[\s]+", "-", s.strip())
        s = re.sub(r"-+", "-", s)
        return s

    cats_dir = base / "categories"
    feeds = []
    for fp in sorted(cats_dir.glob("*.json")):
        with open(fp) as f:
            feeds.extend(json.load(f))

    with open(base / "descriptions_raw.json") as f:
        fetched = json.load(f)

    og_map = {r["name"]: r.get("og") or "" for r in fetched}

    changed = 0
    for feed in feeds:
        name = feed["name"]
        current = feed.get("description", "")
        og = og_map.get(name, "")
        refined = pick_best(name, current, og)

        if refined != current:
            changed += 1
            feed["description"] = refined

    # Write back to category files
    from collections import defaultdict
    grouped = defaultdict(list)
    for feed in feeds:
        grouped[feed["category"]].append(feed)

    for cat, cat_feeds in grouped.items():
        cat_feeds.sort(key=lambda f: f["name"].lower())
        filename = slugify(cat) + ".json"
        with open(cats_dir / filename, "w") as f:
            json.dump(cat_feeds, f, indent=2, ensure_ascii=False, sort_keys=True)
            f.write("\n")

    print(f"Updated {changed} of {len(feeds)} descriptions")


if __name__ == "__main__":
    main()
