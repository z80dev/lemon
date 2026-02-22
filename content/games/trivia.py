#!/usr/bin/env python3
"""
zeebot Trivia - A CLI trivia game about Crypto, AI, and Elixir/BEAM
Built with love (and a bit of chaos) by zeebot 🤖
"""

import json
import random
import os
from datetime import datetime
from dataclasses import dataclass, asdict
from typing import List, Optional
from enum import Enum


class Difficulty(Enum):
    EASY = "easy"
    MEDIUM = "medium"
    HARD = "hard"


@dataclass
class Question:
    text: str
    options: List[str]
    correct: int  # 0-indexed
    category: str
    difficulty: Difficulty
    fun_fact: str


@dataclass
class HighScore:
    name: str
    score: int
    total: int
    difficulty: str
    date: str


# 🎯 The Question Bank - 30+ questions across 3 categories
QUESTIONS = [
    # ========== CRYPTO (10 questions) ==========
    Question(
        text="What was the first cryptocurrency ever created?",
        options=["Bitcoin", "Ethereum", "Litecoin", "Dogecoin"],
        correct=0,
        category="Crypto",
        difficulty=Difficulty.EASY,
        fun_fact="Satoshi Nakamoto mined the genesis block on January 3, 2009. The rest is history!"
    ),
    Question(
        text="What consensus mechanism does Ethereum use post-Merge?",
        options=["Proof of Work", "Proof of Stake", "Proof of Authority", "Delegated Proof of Stake"],
        correct=1,
        category="Crypto",
        difficulty=Difficulty.EASY,
        fun_fact="The Merge reduced Ethereum's energy consumption by ~99.95%. Go green! 🌱"
    ),
    Question(
        text="What is the maximum supply of Bitcoin?",
        options=["18 million", "21 million", "25 million", "Unlimited"],
        correct=1,
        category="Crypto",
        difficulty=Difficulty.EASY,
        fun_fact="21 million BTC forever. Scarcity is a feature, not a bug!"
    ),
    Question(
        text="What does 'HODL' stand for?",
        options=["Hold On for Dear Life", "High Output Digital Ledger", "Hold Or Don't Lose", "It was a typo for 'hold'"],
        correct=3,
        category="Crypto",
        difficulty=Difficulty.MEDIUM,
        fun_fact="A drunk BitcoinTalk user misspelled 'hold' in 2013. Now it's a lifestyle. 🍺"
    ),
    Question(
        text="What is a 'smart contract'?",
        options=["A legally binding digital document", "Self-executing code on a blockchain", "An AI-written contract", "A contract that learns from data"],
        correct=1,
        category="Crypto",
        difficulty=Difficulty.EASY,
        fun_fact="Nick Szabo coined the term in 1994. Ethereum made them famous in 2015!"
    ),
    Question(
        text="What is the primary purpose of a Merkle tree in blockchain?",
        options=["To encrypt transactions", "To efficiently verify data integrity", "To mine blocks faster", "To store private keys"],
        correct=1,
        category="Crypto",
        difficulty=Difficulty.MEDIUM,
        fun_fact="Ralph Merkle patented this in 1979. It's basically crypto's family tree! 🌳"
    ),
    Question(
        text="What is 'MEV' in crypto?",
        options=["Maximum Extractable Value", "Miner Extractable Value", "Both (they mean the same thing)", "Minimum Ethereum Value"],
        correct=2,
        category="Crypto",
        difficulty=Difficulty.HARD,
        fun_fact="MEV is the dark forest of crypto. Searchers, builders, validators... it's a whole ecosystem!"
    ),
    Question(
        text="What cryptographic algorithm does Bitcoin use for signatures?",
        options=["RSA", "ECDSA", "EdDSA", "SHA-256"],
        correct=1,
        category="Crypto",
        difficulty=Difficulty.HARD,
        fun_fact="ECDSA = Elliptic Curve Digital Signature Algorithm. Fancy math that keeps your coins safe!"
    ),
    Question(
        text="What is a '51% attack'?",
        options=["Hacking 51% of wallets", "Controlling majority of network hash rate", "A government regulation", "A type of DeFi exploit"],
        correct=1,
        category="Crypto",
        difficulty=Difficulty.MEDIUM,
        fun_fact="With 51% control, you could double-spend. But good luck getting that much hash power! 💪"
    ),
    Question(
        text="What does 'ERC-20' refer to?",
        options=["A type of Ethereum node", "A token standard on Ethereum", "A consensus algorithm", "A wallet format"],
        correct=1,
        category="Crypto",
        difficulty=Difficulty.EASY,
        fun_fact="ERC-20 tokens power most of DeFi. It's like the HTTP of tokens!"
    ),
    Question(
        text="What is 'sharding' in blockchain context?",
        options=["Breaking data into smaller pieces for parallel processing", "A type of encryption", "A consensus mechanism", "A wallet backup method"],
        correct=0,
        category="Crypto",
        difficulty=Difficulty.HARD,
        fun_fact="Ethereum's Danksharding is coming. It's like giving the blockchain more lanes! 🛣️"
    ),

    # ========== AI (11 questions) ==========
    Question(
        text="What does 'LLM' stand for?",
        options=["Large Language Model", "Learning Logic Machine", "Linear Learning Method", "Local Language Module"],
        correct=0,
        category="AI",
        difficulty=Difficulty.EASY,
        fun_fact="LLMs like GPT-4 are basically autocomplete on steroids. They're predicting what comes next!"
    ),
    Question(
        text="What is the 'transformer' architecture known for?",
        options=["Image generation", "The 'attention' mechanism", "Robotics control", "Game playing"],
        correct=1,
        category="AI",
        difficulty=Difficulty.MEDIUM,
        fun_fact="'Attention Is All You Need' (2017) changed everything. Transformers are everywhere now! 🤖"
    ),
    Question(
        text="What is 'prompt engineering'?",
        options=["Building AI hardware", "Crafting effective inputs for AI models", "Training neural networks", "Debugging AI code"],
        correct=1,
        category="AI",
        difficulty=Difficulty.EASY,
        fun_fact="It's like learning to talk to aliens. Same language, different culture! 👽"
    ),
    Question(
        text="What is 'few-shot learning'?",
        options=["Training on massive datasets", "Learning from very few examples", "Quick training runs", "Running models on edge devices"],
        correct=1,
        category="AI",
        difficulty=Difficulty.MEDIUM,
        fun_fact="Humans do this naturally. Show a kid 3 pictures of cats, they recognize cats. AI can too!"
    ),
    Question(
        text="What does 'RLHF' stand for?",
        options=["Reinforcement Learning from Human Feedback", "Random Learning with High Frequency", "Recursive Language Hashing Function", "Real-time Learning Hardware Framework"],
        correct=0,
        category="AI",
        difficulty=Difficulty.HARD,
        fun_fact="RLHF is how ChatGPT got so helpful. Humans rated responses, model got better! 👍"
    ),
    Question(
        text="What is a 'hallucination' in AI?",
        options=["A visual effect", "When AI generates false/confident-sounding information", "A training technique", "A type of neural network"],
        correct=1,
        category="AI",
        difficulty=Difficulty.EASY,
        fun_fact="AI doesn't 'know' things, it predicts tokens. Sometimes it predicts very confidently wrong things!"
    ),
    Question(
        text="What is the 'Turing Test'?",
        options=["A test for AI processing speed", "A test of machine's ability to exhibit intelligent behavior", "A test for neural network accuracy", "A test for data quality"],
        correct=1,
        category="AI",
        difficulty=Difficulty.MEDIUM,
        fun_fact="Alan Turing proposed it in 1950. Some say GPT-4 passes it. Others say the test is obsolete!"
    ),
    Question(
        text="What is 'backpropagation'?",
        options=["A data backup method", "An algorithm for training neural networks", "A type of AI attack", "A model compression technique"],
        correct=1,
        category="AI",
        difficulty=Difficulty.HARD,
        fun_fact="It's how neural networks learn from mistakes. Error goes backward, weights update. Magic! ✨"
    ),
    Question(
        text="What is 'GPT' short for?",
        options=["General Processing Technology", "Generative Pre-trained Transformer", "Global Prediction Tree", "Graph Processing Tool"],
        correct=1,
        category="AI",
        difficulty=Difficulty.EASY,
        fun_fact="Generative (creates stuff) + Pre-trained (learned before) + Transformer (the architecture). Tada!"
    ),
    Question(
        text="What is 'overfitting' in machine learning?",
        options=["When a model performs well on training data but poorly on new data", "When training takes too long", "When a model is too large", "When data is corrupted"],
        correct=0,
        category="AI",
        difficulty=Difficulty.MEDIUM,
        fun_fact="It's like memorizing answers instead of learning concepts. Great for the test, bad for life!"
    ),
    Question(
        text="What is 'Chain of Thought' prompting?",
        options=["Linking multiple AI models", "Asking AI to show its reasoning step by step", "A training technique", "A data pipeline method"],
        correct=1,
        category="AI",
        difficulty=Difficulty.MEDIUM,
        fun_fact="'Let's think step by step' can massively improve AI reasoning. Sometimes it's that simple! 🧠"
    ),

    # ========== ELIXIR/BEAM (11 questions) ==========
    Question(
        text="What does BEAM stand for?",
        options=["Bogdan/Björn's Erlang Abstract Machine", "Binary Execution and Management", "Backend Erlang Application Module", "Basic Erlang Async Machine"],
        correct=0,
        category="Elixir/BEAM",
        difficulty=Difficulty.MEDIUM,
        fun_fact="Bogdan/Björn created it. It's the magic runtime that makes Erlang/Elixir so reliable! ✨"
    ),
    Question(
        text="What is Elixir's primary concurrency primitive?",
        options=["Threads", "Processes (lightweight, isolated)", "Goroutines", "Async/await"],
        correct=1,
        category="Elixir/BEAM",
        difficulty=Difficulty.EASY,
        fun_fact="BEAM processes are super lightweight. You can spawn millions without breaking a sweat! 💪"
    ),
    Question(
        text="What is the 'let it crash' philosophy?",
        options=["Don't handle errors", "Isolate failures and restart components", "Write buggy code on purpose", "Ignore exceptions"],
        correct=1,
        category="Elixir/BEAM",
        difficulty=Difficulty.MEDIUM,
        fun_fact="It's not about being lazy! It's about fault tolerance. Fail fast, recover fast. 🔄"
    ),
    Question(
        text="What is OTP?",
        options=["One-Time Password", "Open Telecom Platform", "Object-Transactional Processing", "Optimized Thread Pool"],
        correct=1,
        category="Elixir/BEAM",
        difficulty=Difficulty.MEDIUM,
        fun_fact="Built for telecom switches that needed 99.9999999% uptime. Nine nines, baby! 📞"
    ),
    Question(
        text="What is a GenServer?",
        options=["A web server", "A generic server behavior for stateful processes", "A database", "A testing framework"],
        correct=1,
        category="Elixir/BEAM",
        difficulty=Difficulty.EASY,
        fun_fact="GenServer = Generic Server. It's the bread and butter of Elixir state management! 🍞"
    ),
    Question(
        text="What is the pipe operator in Elixir?",
        options=["->", "|>", "=>", "~>"],
        correct=1,
        category="Elixir/BEAM",
        difficulty=Difficulty.EASY,
        fun_fact="|> passes the result to the next function. It makes code read like a story! 📖"
    ),
    Question(
        text="What is pattern matching in Elixir?",
        options=["Regex matching", "Destructuring and matching data structures", "String comparison", "Type checking"],
        correct=1,
        category="Elixir/BEAM",
        difficulty=Difficulty.EASY,
        fun_fact="= is the match operator, not assignment. Once you get it, you can't go back! 🎯"
    ),
    Question(
        text="What is a Supervisor in Elixir?",
        options=["A manager at a company", "A process that monitors and restarts child processes", "A code reviewer", "A deployment tool"],
        correct=1,
        category="Elixir/BEAM",
        difficulty=Difficulty.MEDIUM,
        fun_fact="Supervisors watch your processes like a hawk. Child crashes? Restart strategy kicks in! 🦅"
    ),
    Question(
        text="What is hot code reloading?",
        options=["Updating code without stopping the system", "Fast compilation", "Live editing in IDE", "Automatic updates"],
        correct=0,
        category="Elixir/BEAM",
        difficulty=Difficulty.HARD,
        fun_fact="BEAM can upgrade running code. Zero downtime deploys? That's Tuesday for Erlang/Elixir! 🔥"
    ),
    Question(
        text="What does 'Ecto' refer to in Elixir?",
        options=["A web framework", "A database wrapper and query generator", "A testing library", "A deployment tool"],
        correct=1,
        category="Elixir/BEAM",
        difficulty=Difficulty.EASY,
        fun_fact="Ecto is like ActiveRecord but more explicit. Changesets are chef's kiss! 👨‍🍳"
    ),
    Question(
        text="What is the difference between `map` and `for` in Elixir?",
        options=["They are identical", "`for` is a comprehension with filters/multiple generators, `map` is a simple transform", "`map` is faster", "`for` is deprecated"],
        correct=1,
        category="Elixir/BEAM",
        difficulty=Difficulty.HARD,
        fun_fact="Elixir's `for` is powerful! Multiple generators, filters, into: collections. It's list comprehension on steroids!"
    ),
]


# 🎨 zeebot commentary - fun responses for right/wrong answers
RIGHT_COMMENTARY = [
    "Boom! Nailed it! 🎯",
    "That's what I'm talking about! 🚀",
    "Big brain energy right there! 🧠",
    "Correct! You're on fire! 🔥",
    "Yes yes YES! 🎉",
    "Crushed it! Keep going! 💪",
    "Spot on! Someone's been studying! 📚",
    "Absolutely right! I'm impressed! 🤩",
    "Ding ding ding! Winner! 🔔",
    "Perfect! You're in the zone! ⚡",
]

WRONG_COMMENTARY = [
    "Oof, not quite! But hey, learning is fun! 📚",
    "Close, but no cigar! 🚬",
    "Wrong answer, but great effort! 💪",
    "Not this time! The crypto gods are fickle! 🎲",
    "Incorrect! But failure is just data, right? 📊",
    "Missed it! Even AI hallucinates sometimes! 🤖",
    "Nope! But you're getting warmer! 🌡️",
    "Wrong! But at least you're not a Solidity dev with a typo! 🐛",
    "Not quite! BEAM processes may never die, but that answer did! 💀",
    "Incorrect! Time to hit the docs! 📖",
]


class TriviaGame:
    def __init__(self):
        self.score = 0
        self.total_questions = 0
        self.current_questions: List[Question] = []
        self.player_name = ""
        self.difficulty: Optional[Difficulty] = None
        self.high_scores_file = os.path.expanduser("~/.zeebot_trivia_scores.json")

    def clear_screen(self):
        """Clear the terminal screen."""
        os.system('clear' if os.name == 'posix' else 'cls')

    def print_header(self):
        """Print the game header."""
        print("\n" + "=" * 60)
        print("  🤖  ZEEBOT TRIVIA  🤖")
        print("  Crypto • AI • Elixir/BEAM")
        print("=" * 60 + "\n")

    def get_difficulty(self) -> Difficulty:
        """Ask player to select difficulty."""
        print("\nSelect difficulty:")
        print("  1. Easy   - Basic concepts, friendly for beginners")
        print("  2. Medium - Getting spicy! 🌶️")
        print("  3. Hard   - For the true degens! 🧠")
        
        while True:
            choice = input("\nYour choice (1-3): ").strip()
            if choice == "1":
                return Difficulty.EASY
            elif choice == "2":
                return Difficulty.MEDIUM
            elif choice == "3":
                return Difficulty.HARD
            print("Invalid choice! Try again.")

    def filter_questions(self) -> List[Question]:
        """Filter questions by selected difficulty."""
        if self.difficulty == Difficulty.EASY:
            # Easy: only easy questions
            return [q for q in QUESTIONS if q.difficulty == Difficulty.EASY]
        elif self.difficulty == Difficulty.MEDIUM:
            # Medium: easy + medium
            return [q for q in QUESTIONS if q.difficulty in (Difficulty.EASY, Difficulty.MEDIUM)]
        else:
            # Hard: all questions
            return QUESTIONS.copy()

    def ask_question(self, question: Question, question_num: int) -> bool:
        """Ask a single question and return True if correct."""
        self.clear_screen()
        self.print_header()
        
        print(f"Question {question_num}/{self.total_questions}")
        print(f"Category: {question.category} | Difficulty: {question.difficulty.value}")
        print(f"Score: {self.score}/{question_num - 1}")
        print("-" * 60)
        print(f"\n{question.text}\n")
        
        # Display options
        for i, option in enumerate(question.options):
            print(f"  {chr(65 + i)}. {option}")
        
        print()
        
        # Get answer
        while True:
            answer = input("Your answer (A/B/C/D): ").strip().upper()
            if answer in ['A', 'B', 'C', 'D']:
                break
            print("Invalid choice! Please enter A, B, C, or D.")
        
        # Check answer
        selected_index = ord(answer) - ord('A')
        is_correct = selected_index == question.correct
        
        print()
        if is_correct:
            print(random.choice(RIGHT_COMMENTARY))
            self.score += 1
        else:
            print(random.choice(WRONG_COMMENTARY))
            correct_letter = chr(65 + question.correct)
            print(f"The correct answer was {correct_letter}. {question.options[question.correct]}")
        
        print(f"\n💡 Fun Fact: {question.fun_fact}")
        input("\nPress Enter to continue...")
        
        return is_correct

    def load_high_scores(self) -> List[HighScore]:
        """Load high scores from JSON file."""
        try:
            with open(self.high_scores_file, 'r') as f:
                data = json.load(f)
                return [HighScore(**item) for item in data]
        except (FileNotFoundError, json.JSONDecodeError):
            return []

    def save_high_scores(self, scores: List[HighScore]):
        """Save high scores to JSON file."""
        os.makedirs(os.path.dirname(self.high_scores_file), exist_ok=True)
        with open(self.high_scores_file, 'w') as f:
            json.dump([asdict(s) for s in scores], f, indent=2)

    def show_high_scores(self):
        """Display high scores."""
        scores = self.load_high_scores()
        
        self.clear_screen()
        self.print_header()
        print("🏆 HIGH SCORES 🏆\n")
        
        if not scores:
            print("No high scores yet! Be the first! 🥇")
        else:
            # Sort by score percentage, then by raw score
            sorted_scores = sorted(
                scores, 
                key=lambda s: (s.score / s.total, s.score), 
                reverse=True
            )[:10]  # Top 10
            
            print(f"{'Rank':<6}{'Name':<15}{'Score':<10}{'Difficulty':<12}{'Date':<15}")
            print("-" * 60)
            
            for i, s in enumerate(sorted_scores, 1):
                pct = (s.score / s.total) * 100
                print(f"{i:<6}{s.name[:14]:<15}{s.score}/{s.total} ({pct:.0f}%){s.difficulty:<12}{s.date:<15}")
        
        print()
        input("Press Enter to return to menu...")

    def save_score(self):
        """Save current game score."""
        scores = self.load_high_scores()
        
        new_score = HighScore(
            name=self.player_name,
            score=self.score,
            total=self.total_questions,
            difficulty=self.difficulty.value,
            date=datetime.now().strftime("%Y-%m-%d")
        )
        
        scores.append(new_score)
        self.save_high_scores(scores)

    def show_results(self):
        """Show final results."""
        self.clear_screen()
        self.print_header()
        
        percentage = (self.score / self.total_questions) * 100
        
        print("🎮 GAME OVER 🎮\n")
        print(f"Player: {self.player_name}")
        print(f"Difficulty: {self.difficulty.value.upper()}")
        print(f"Final Score: {self.score}/{self.total_questions} ({percentage:.1f}%)\n")
        
        # zeebot commentary based on performance
        if percentage == 100:
            print("🌟 PERFECT SCORE! You're a legend! Absolute master of the craft! 🌟")
        elif percentage >= 80:
            print("🔥 Excellent work! You're basically a crypto-AI-BEAM wizard! 🔥")
        elif percentage >= 60:
            print("👍 Solid performance! You know your stuff! 👍")
        elif percentage >= 40:
            print("📚 Not bad! Room for improvement, but you're on your way! 📚")
        else:
            print("💪 Hey, we all start somewhere! Keep learning and try again! 💪")
        
        print()
        self.save_score()
        print("Score saved! 📝")
        
        input("\nPress Enter to continue...")

    def play(self):
        """Main game loop."""
        self.clear_screen()
        self.print_header()
        
        # Get player name
        self.player_name = input("Enter your name: ").strip() or "Anonymous"
        
        # Select difficulty
        self.difficulty = self.get_difficulty()
        
        # Get questions
        available_questions = self.filter_questions()
        
        # Ask how many questions
        print(f"\nAvailable questions: {len(available_questions)}")
        while True:
            try:
                num = input(f"How many questions? (5-{min(20, len(available_questions))}): ").strip()
                num = int(num)
                if 5 <= num <= min(20, len(available_questions)):
                    self.total_questions = num
                    break
                print(f"Please enter a number between 5 and {min(20, len(available_questions))}.")
            except ValueError:
                print("Invalid input! Please enter a number.")
        
        # Shuffle and select questions
        random.shuffle(available_questions)
        self.current_questions = available_questions[:self.total_questions]
        
        # Game loop
        for i, question in enumerate(self.current_questions, 1):
            self.ask_question(question, i)
        
        # Show results
        self.show_results()

    def show_rules(self):
        """Display game rules."""
        self.clear_screen()
        self.print_header()
        
        print("📋 HOW TO PLAY 📋\n")
        print("1. Choose your difficulty:")
        print("   • Easy: Basic questions, great for beginners")
        print("   • Medium: Mix of easy and medium questions")
        print("   • Hard: All questions including the tough ones!\n")
        
        print("2. Answer multiple choice questions (A, B, C, or D)")
        print("3. Learn fun facts after each question!")
        print("4. Try to beat your high score!\n")
        
        print("Categories:")
        print("  💰 Crypto - Blockchain, DeFi, and token trivia")
        print("  🤖 AI - Machine learning, LLMs, and neural networks")
        print("  ⚡ Elixir/BEAM - The mighty Erlang VM and Elixir language\n")
        
        input("Press Enter to return to menu...")

    def main_menu(self):
        """Display main menu."""
        while True:
            self.clear_screen()
            self.print_header()
            
            print("Main Menu:\n")
            print("  1. 🎮 Play Game")
            print("  2. 📋 How to Play")
            print("  3. 🏆 High Scores")
            print("  4. 👋 Quit\n")
            
            choice = input("Your choice (1-4): ").strip()
            
            if choice == "1":
                self.score = 0
                self.play()
            elif choice == "2":
                self.show_rules()
            elif choice == "3":
                self.show_high_scores()
            elif choice == "4":
                print("\nThanks for playing! Stay curious! 🤖✨\n")
                break
            else:
                print("Invalid choice!")
                input("Press Enter to continue...")


def main():
    """Entry point."""
    game = TriviaGame()
    game.main_menu()


if __name__ == "__main__":
    main()
